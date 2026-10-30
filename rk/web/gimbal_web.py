# -*- coding: utf-8 -*-
"""云台（QGimbal，USB CDC-ACM）Web 控制后端。

由 ``mipi_webstream.py`` 实例化一份挂在 ``/api/gimbal`` 上，页面在
``mipi_viewer.html`` 的「云台」页签里用。串口命令协议直接复用
``rk/gimbal/gimbal_keyctrl.py`` 里已经验证过的 ``Link`` / ``Gimbal``。

=====================================================================
安全设计（**排线会被扯断，任何一条都不能省**）
=====================================================================
1. **只用绝对角度模式** ``ctrl angle yaw pitch``，不发 ``ctrl speed``。
   速度模式没有位置闭环：客户端一掉线、看门狗一失效，云台就一直转，
   一直转到把排线扯断为止。角度模式的目标值本身受限幅约束，
   就算本进程被杀，云台也只会停在最后一个（已限幅的）目标上。

2. **所有目标在下发前双重限幅**（见 ``_effective_limits()``）：
     * 绝对限幅：固件关节角坐标的 ±yaw_abs（默认 170°，用户要求 ±180° 以内）
       以及 ±(固件 ``limit.pitch.deg`` − 1°) —— 这条和"零点设在哪"无关，
       所以就算零点设歪了，也不会多转半圈。
     * 相对限幅：软件零点 ±yaw_limit / ±pitch_limit（默认 170° / 42°）。
   两者取交集，任何时刻下发的目标都落在交集内。

3. **看门狗**：手动点动（jog）必须每隔 ``hold`` 秒续一次，超时自动归零；
   页面还会在 pointerup / blur / visibilitychange 时主动发 ``stop``。
   双保险：即使浏览器崩了，云台最多再走 hold 秒。

4. **串口只被一个控制线程持有**，HTTP 线程只往队列里塞命令，不碰串口。

5. 运动指令**被固件拒绝**（超限 / 失能 / STALE）时立刻回滚到上一次
   成功的目标并停止追踪，避免"每拍重试 → 一直报错"。

单位约定：对外（JSON / 页面 / 日志）一律「度」，与串口交互时转弧度。
"""
from __future__ import annotations

import math
import os
import re
import sys
import threading
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


# ------------------------------------------------------------------ 依赖
def _load_driver():
    """复用 gimbal_keyctrl.py 的串口与命令封装。

    仓库布局是 rk/web 与 rk/gimbal 平级；但**板上**实际把脚本放在
    /root/gimbal_keyctrl.py（扁平存放，见 QUICKSTART），所以两个位置都要找。
    都找不到就退回"不可用"，网页上会显示原因，不影响推流。
    """
    for p in (os.path.join(_HERE, "..", "gimbal"),     # <root>/rk/gimbal
              os.path.join(_HERE, "..", ".."),         # <root>/rk
              os.path.join(_HERE, "..", "..", ".."),   # 板上 = /root
              "/root",
              "/root/rk/gimbal",
              _HERE):
        p = os.path.abspath(p)
        if os.path.isdir(p) and p not in sys.path:
            sys.path.append(p)
    try:
        from gimbal_keyctrl import Link, Gimbal        # noqa: WPS433
        return Link, Gimbal, ""
    except Exception as e:                             # noqa: BLE001
        return None, None, "%s: %s" % (type(e).__name__, e)


Link, Gimbal, DRIVER_ERR = _load_driver()

try:
    import state_store
except Exception:                                      # noqa: BLE001
    state_store = None

# 与 gimbal_keyctrl.py 保持一致的 status 行解析（Angle / Speed 各一行）
_ANGLE_RE = r'^\s+%s\s*:\s*yaw:([-+0-9.eE]+)\s+(?:rad|rpm),\s*pitch:([-+0-9.eE]+)'
_ENABLED_RE = r'[Ee]nabled\s*[:=]\s*([A-Za-z0-9_]+)'
_REJECT = re.compile(r'failed|Command not Found|STALE|\bnan\b|\binf\b', re.I)


def _num(v, d=0.0):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return d
    if f != f or f in (float("inf"), float("-inf")):
        return d
    return f


def _clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def _round(v, n=1):
    return None if v is None else round(float(v), n)


def _is_io_dead(exc):
    """这个异常是不是"串口已经废了"（USB 掉线 / EIO），而不是固件拒绝了命令。

    区别很重要：固件拒绝（STALE / failed）说明链路是好的，重发没用但不能重连；
    EIO / 设备消失说明 fd 已经失效，必须关掉重开，否则会永远卡在
    connected=True 却什么都发不出去（2026-10-28 实测）。
    """
    s = "%s" % exc
    if isinstance(exc, OSError) and not isinstance(exc, TimeoutError):
        return True
    for kw in ("Input/output error", "No such device", "Device or resource busy",
               "Bad file descriptor", "Errno 5", "Errno 19"):
        if kw.lower() in s.lower():
            return True
    return False


def _stop_speed(g):
    if g is None:
        return
    try:
        g.speed(0.0, 0.0)
    except Exception:                                    # noqa: BLE001
        pass


class _KalmanCV(object):
    """一维「匀速」卡尔曼：状态 = [位置, 速度]，测量只有位置。

    用在云台追踪上：
      * 位置 = 目标中心偏离画面中心多少（归一化 -1~1）
      * 速度 = 这个偏差的变化率（1/s）
    作用有三：把检测框的抖动滤掉、帧间（AI 只有 30fps）用模型外推保持连续、
    并且能往前预测 T_pred 秒弥补「AI + 串口」的流水线延迟 —— 相机就会
    领着人走，而不是一步一超。

    r = 测量方差（框中心抖动的方差，归一化单位；0.016 σ ≈ 5px/320px）
    q = 过程噪声谱密度（目标加速度的不确定性；越大越跟手，越小越平滑）
    """

    def __init__(self, r=5e-4, q=0.8):
        self.r = max(1e-6, float(r))
        self.q = max(1e-6, float(q))
        self.x = None                 # [pos, vel]
        self.P = [[1.0, 0.0], [0.0, 1.0]]

    def reset(self, z=None):
        self.x = None if z is None else [float(z), 0.0]
        self.P = [[max(self.r, 1e-3), 0.0], [0.0, 1.0]]
        return self.x

    def predict(self, dt):
        """只做预测，不摄入新测量（两次 AI 结果之间的外推）。"""
        if self.x is None:
            return None
        dt = _clamp(dt, 1e-3, 0.5)
        p, v = self.x
        p = p + v * dt
        P = self.P
        q = self.q
        P00 = P[0][0] + dt * (P[1][0] + P[0][1]) + dt * dt * P[1][1] + q * dt ** 3 / 3.0
        P01 = P[0][1] + dt * P[1][1] + q * dt ** 2 / 2.0
        P10 = P[1][0] + dt * P[1][1] + q * dt ** 2 / 2.0
        P11 = P[1][1] + q * dt
        self.P = [[P00, P01], [P10, P11]]
        self.x = [p, v]
        return self.x

    def update(self, z, dt, max_vel=3.0):
        """摄入一帧新测量，返回平滑后的 [pos, vel]。"""
        if self.x is None:
            return self.reset(z)
        self.predict(dt)
        p, v = self.x
        P00, P01 = self.P[0]
        P10, P11 = self.P[1]
        S = P00 + self.r
        K0 = P00 / S
        K1 = P10 / S
        y = float(z) - p
        p += K0 * y
        v += K1 * y
        self.P = [[(1.0 - K0) * P00, (1.0 - K0) * P01],
                  [(1.0 - K0) * P10, (1.0 - K0) * P11]]
        v = _clamp(v, -max_vel, max_vel)
        self.x = [p, v]
        return self.x

    def pos_at(self, ahead):
        """按速度外推 ahead 秒后的位置（不等新测量）。"""
        if self.x is None:
            return None
        return self.x[0] + self.x[1] * max(0.0, ahead)


class GimbalWeb(object):
    """云台控制：串口线程 + 限幅 + 点动 + 回零 + YOLO 目标追踪（卡尔曼预测）。"""

    PERIOD = 0.025         # 主控制周期（秒）。0.06 太粗 —— 每拍要挪 1.5°，
                           # 固件到点就停一下再等下一拍，看起来就是「一顿一顿」
    TELEMETRY = 0.30       # 空闲时 status 轮询周期（秒）
    TELEMETRY_MOVING = 1.0 # 运动中放慢：每次 status 会占 15~40ms 总线，
                           # 0.3s 一读就是 3Hz 的卡顿（实测现象）
    JOG_HOLD = 0.8         # 点动保持时间（秒）—— 页面每 200ms 续一次
    BAUD = 115200
    REPLY_TIMEOUT = 0.8
    RATE_RESEND = 0.10     # 速度心跳：变化小于阈值也每 100ms 重发一次
    GUARD_S = 0.6          # 看门狗：控制线程超过这个时间没更新速度就补发 0
    POS_EXTRAP_MAX = 0.4   # 编码器角最多外推 0.4s（再长就是瞎猜，会自激）
    # ★ 位置环死区/限幅（2026-10-30）：点动结束后目标会超前实测位置（JOG_HOLD 0.8s
    #   的尾巴 + 斜坡），位置环就以最高 2°/s 去追这个不存在的目标 ——
    #   用户看到的就是“松开方向键后云台自己还在慢慢转”。
    POS_FB_TOL = 2.0       # 小于它一律不动（度）
    POS_FB_MAX = 1.0       # 最大修正速度（度/秒）

    def __init__(self, port="/dev/ttyACM0", yaw_limit_deg=170.0,
                 pitch_limit_deg=42.0, speed_max=25.0,
                 yaw_sign=1.0, pitch_sign=1.0, state_path=None,
                 ai_status=None, ai_ensure=None, verbose=False,
                 accel_deg_s2=250.0, predict_s=0.15,
                 kalman=True, kf_r=5e-4, kf_q=0.8, period=None,
                 loop="vel", kp_vel=0.5, lead_max=12.0, auto_open=True,
                 drive="speed"):
        self.port = str(port or "").strip()
        self.speed_max = _clamp(_num(speed_max, 25.0), 1.0, 90.0)
        # 相对软件零点的限幅（用户要求：左右 180°、俯仰 45°）
        self.yaw_limit = _clamp(abs(_num(yaw_limit_deg, 170.0)), 1.0, 178.0)
        self.pitch_limit = _clamp(abs(_num(pitch_limit_deg, 42.0)), 1.0, 45.0)
        # 绝对限幅（固件关节角坐标；和零点无关的那层保险）
        self.yaw_abs = min(self.yaw_limit, 170.0)
        self.pitch_abs = min(self.pitch_limit, 42.0)
        self.yaw_sign = 1.0 if _num(yaw_sign, 1.0) >= 0 else -1.0
        self.pitch_sign = 1.0 if _num(pitch_sign, 1.0) >= 0 else -1.0
        # 死区从 0.07 改到 0.015：原来的大死区 + 框抖动 = 「走一下停一下」。
        # 现在误差先过卡尔曼，抖动没了，死区只用来防止静座时的微颤。
        self.track_deadband = 0.015
        self.track_full = 0.35           # |误差| 到这里给满速
        self.track_gain = 1.0
        # 平滑：所有速度指令都按这个加速度斜坡上去/下来，不再阶跃
        self.accel = _clamp(_num(accel_deg_s2, 250.0), 10.0, 3000.0)
        self.predict_s = _clamp(_num(predict_s, 0.15), 0.0, 0.6)
        self.kalman = bool(kalman)
        self.kf_r = _num(kf_r, 5e-4)
        self.kf_q = _num(kf_q, 0.8)
        self.period = _clamp(_num(period, self.PERIOD), 0.01, 0.2)
        # ---- 双闭环 ----
        #   外环（位置）：慢速/静止时才闭合，把目标朝编码器角度收敛（限速 2°/s）
        #   内环（速度）：用编码器测速给目标推进"封顶"，防止跟不上时积分饱和
        #   loop="ff" : 两个环都关掉，只做速度前馈（旧行为，便于对比/回退）
        self.loop = "ff" if str(loop).lower() in ("ff", "open", "pos") else "vel"
        self.kp_vel = _clamp(_num(kp_vel, 0.5), 0.0, 2.0)
        # 堵转保护：目标允许超前实测多少度。正常跟随只有零点几度，
        # 超过它就不再推进目标（等云台跟上来），避免放开后猛冲一大段。
        self.lead_max = _clamp(_num(lead_max, 12.0), 1.0, 60.0)
        # ---- 驱动方式 ----
        #   speed : 连续控制（默认）—— 每拍下发 ctrl speed，云台**连续转**，
        #           不会像角度模式那样“到点就停一下”（用户说的步进感）。
        #           固件在速度模式下不替你限位，软限位/看门狗全在本类里做。
        #   angle : 步进控制（旧行为）—— 每拍下发 ctrl angle 绝对角，固件
        #           到点停；精度好但 25ms 一步，视觉上“一顿一顿”。
        self.drive = ("angle" if str(drive or "").lower().startswith("a")
                      else "speed")
        self.state_path = state_path
        self.ai_status = ai_status       # () -> dict | None
        self.ai_ensure = ai_ensure       # () -> str（提示语）
        self.verbose = bool(verbose)

        self.lock = threading.Lock()
        self._wake = threading.Event()
        self._stop_evt = threading.Event()
        self._tasks = []
        self._link = None
        self._g = None
        self._thr = None
        self._guard_thr = None
        # auto_open: 服务一起来就抢串口并做 ready 序列。
        # ⚠ 早先这里是 False，于是每次 systemctl restart 之后页面都显示
        #   「未连接」，必须点一下方向键才连上（用户会误以为坏了）。
        self._want_open = bool(auto_open)
        self._sent = None                 # 上一次成功下发的目标（度）
        self._sent_rate = None            # 上一次下发的速度指令（rpm, Y/P）
        self._t_cmd = 0.0                 # 上一次成功下发速度的时刻（看门狗用）
        self._limit_hit = [False, False]  # 软限位刹车是否介入（给页面看）
        self._homing_until = 0.0

        # ---- 对外状态 ----
        self.available = bool(Link) and bool(self.port)
        self.connected = False
        self.enabled = None               # True/False/None(未知)
        self.fw_pitch_limit = None        # 固件 limit.pitch.deg（读不到 = None）
        self.angle = None                 # [yaw, pitch] 度（固件关节角）
        self.rate = [None, None]          # status 的 Speed（rpm）
        self.zero = [0.0, 0.0]            # 软件零点（固件坐标，度）
        self.target = None                # 当前目标（固件坐标，度）
        self.jog = [0.0, 0.0]             # 页面要求的点动速度（度/秒）
        self.jog_until = 0.0
        self._feed_prev = False           # 上一拍是否有前馈（点动/追踪）
        self.tracking = False
        self.track = {"state": "未开启"}
        self.rate_cmd = [0.0, 0.0]        # 斜坡后的实际速度指令（度/秒）
        self.applied = [0.0, 0.0]         # 本拍实际施加的角速度（度/秒）
        # 卡尔曼（横向/俯仰各一个）；_kf_last_cnt 用来判断 AI 有没有出新结果
        self._kf_x = None
        self._kf_y = None
        self._kf_last_cnt = None
        self._kf_stale = True
        self._aim_s = None               # 平滑后的瞄准点（head<->中心 切换去抖）
        # 双闭环：实测速度(°/s)/积分/修正量；_t_meas = 上次 status 的时刻
        self._t_meas = 0.0
        self._vel_meas = [0.0, 0.0]
        self._vel_meas_hold = [0.0, 0.0]   # 上一次有效的测速（防止瞬时 0 让封顶失效）
        self._stall = [False, False]        # 本拍是否因“目标超前太多”被冻结
        self.ctrl_info = {"loop": self.loop}
        self.msg = "未连接" if self.available else ("云台不可用: %s" % DRIVER_ERR)
        self.last_error = ""
        self._lim = ((0.0, 0.0), (0.0, 0.0))
        self._load_state()
        self._lim = self._effective_limits()

    # ------------------------------------------------------------------ 生命周期
    def start(self):
        if self._thr is not None:
            return
        self._thr = threading.Thread(target=self._loop, name="gimbal-ctl",
                                     daemon=True)
        self._thr.start()
        # 速度模式必须有"没人发指令就停"的保险，否则云台会一直转
        if self.drive == "speed":
            self._guard_thr = threading.Thread(target=self._guard,
                                               name="gimbal-guard",
                                               daemon=True)
            self._guard_thr.start()
        if self.verbose:
            print("[gimbal] 控制线程已启动 port=%s available=%s drive=%s %s"
                  % (self.port, self.available, self.drive, DRIVER_ERR or ""))

    def _guard(self):
        """速度模式的最后一道保险。

        `ctrl speed` 是持续输出：控制线程一旦卡住/异常，云台会按最后一条速度
        **一直转** → 撞限位、刮排线。这里独立检查"上次下发速度多久了"，
        超时就直接往 tty 写一条 `ctrl speed 0 0`。

        ⚠ 故意**不加 `_io` 锁、不等回复**：控制线程卡住时往往正是抱着锁在读
        status（最长 0.8s）。这里只写不读，最多弄乱一次回复，换来能停下来。
        """
        while not self._stop_evt.wait(0.05):
            try:
                if (self.drive != "speed" or not self.connected
                        or self._homing_until or self._g is None
                        or self._t_cmd <= 0.0):
                    continue
                if (time.monotonic() - self._t_cmd) < self.GUARD_S:
                    continue
                fd = getattr(getattr(self._g, "link", None), "fd", None)
                if fd is None:
                    continue
                os.write(fd, b"ctrl speed 0 0\n")
                self._sent_rate = [0.0, 0.0]
                self._t_cmd = time.monotonic()
                self.rate_cmd = [0.0, 0.0]
                self.applied = [0.0, 0.0]
                self.msg = ("看门狗：控制线程 %.1fs 没更新速度，已补发 0"
                            % self.GUARD_S)
                print("[gimbal] 看门狗触发：ctrl speed 0 0")
            except Exception:                            # noqa: BLE001
                pass

    def stop(self):
        self._stop_evt.set()
        self._wake.set()

    # ------------------------------------------------------------------ 状态持久化
    def _load_state(self):
        if state_store is None or not self.state_path:
            return
        st = state_store.get(self.state_path, "gimbal")
        if not isinstance(st, dict):
            return
        z = st.get("zero")
        if isinstance(z, (list, tuple)) and len(z) == 2:
            self.zero = [_clamp(_num(z[0]), -179.0, 179.0),
                         _clamp(_num(z[1]), -90.0, 90.0)]
        if "speed_max" in st:
            self.speed_max = _clamp(_num(st["speed_max"], 25.0), 1.0, 90.0)
        if "yaw_sign" in st:
            self.yaw_sign = 1.0 if _num(st["yaw_sign"], 1.0) >= 0 else -1.0
        if "pitch_sign" in st:
            self.pitch_sign = 1.0 if _num(st["pitch_sign"], 1.0) >= 0 else -1.0
        if "accel" in st:
            self.accel = _clamp(_num(st["accel"], 250.0), 10.0, 3000.0)
        if "predict_s" in st:
            self.predict_s = _clamp(_num(st["predict_s"], 0.15), 0.0, 0.6)
        if "kalman" in st:
            self.kalman = bool(st["kalman"])
        if "period" in st:
            self.period = _clamp(_num(st["period"], self.PERIOD), 0.01, 0.2)
        if "loop" in st:
            self.loop = "ff" if str(st["loop"]).lower() in (
                "ff", "open", "pos") else "vel"
        if "kp_vel" in st:
            self.kp_vel = _clamp(_num(st["kp_vel"], 0.5), 0.0, 2.0)
        if "lead_max" in st:
            self.lead_max = _clamp(_num(st["lead_max"], 12.0), 1.0, 60.0)

    def _save_state(self):
        if state_store is None or not self.state_path:
            return
        state_store.put(self.state_path, "gimbal", {
            "zero": [round(self.zero[0], 2), round(self.zero[1], 2)],
            "speed_max": round(self.speed_max, 1),
            "yaw_sign": self.yaw_sign,
            "pitch_sign": self.pitch_sign,
            "accel": round(self.accel, 1),
            "predict_s": round(self.predict_s, 3),
            "kalman": bool(self.kalman),
            "loop": self.loop,
            "kp_vel": round(self.kp_vel, 3),
            "lead_max": round(self.lead_max, 1),
        })

    # ------------------------------------------------------------------ 限幅
    def _effective_limits(self):
        """返回 ((yaw_lo, yaw_hi), (pitch_lo, pitch_hi))，单位度、固件关节角坐标。

        * 固件 Pitch 限位读不到时按 28° 保守处理（源码默认是 30°）。
        * 相对零点的限幅与绝对限幅取交集。
        """
        fw = self.fw_pitch_limit
        p_abs = (fw - 1.0) if fw else 28.0
        p_abs = _clamp(min(p_abs, self.pitch_abs), 5.0, 60.0)
        y_abs = self.yaw_abs
        y_lo = max(-y_abs, self.zero[0] - self.yaw_limit)
        y_hi = min(y_abs, self.zero[0] + self.yaw_limit)
        p_lo = max(-p_abs, self.zero[1] - self.pitch_limit)
        p_hi = min(p_abs, self.zero[1] + self.pitch_limit)
        if y_lo > y_hi:
            y_lo = y_hi = _clamp(self.zero[0], -y_abs, y_abs)
        if p_lo > p_hi:
            p_lo = p_hi = _clamp(self.zero[1], -p_abs, p_abs)
        return (y_lo, y_hi), (p_lo, p_hi)

    # ------------------------------------------------------------------ HTTP 接口
    def status(self):
        with self.lock:
            yaw, pitch = (self.angle if self.angle else (None, None))
            lim = self._lim
            yrel = None if yaw is None else yaw - self.zero[0]
            prel = None if pitch is None else pitch - self.zero[1]
            return {
                "ok": bool(self.connected),
                "available": self.available,
                "driver_error": DRIVER_ERR,
                "port": self.port,
                "connected": self.connected,
                "enabled": self.enabled,
                "yaw_deg": _round(yaw),
                "pitch_deg": _round(pitch),
                "yaw_rel_deg": _round(yrel),
                "pitch_rel_deg": _round(prel),
                "rate_rpm": [_round(self.rate[0], 2), _round(self.rate[1], 2)],
                "zero": [round(self.zero[0], 1), round(self.zero[1], 1)],
                "target": ([_round(self.target[0]), _round(self.target[1])]
                           if self.target else None),
                "limits": {
                    "yaw_rel": round(self.yaw_limit, 1),
                    "pitch_rel": round(self.pitch_limit, 1),
                    "yaw_abs": round(self.yaw_abs, 1),
                    "pitch_abs": round(lim[1][1], 1),
                    "pitch_fw": (round(self.fw_pitch_limit, 1)
                                 if self.fw_pitch_limit else None),
                    "yaw_range": [round(lim[0][0], 1), round(lim[0][1], 1)],
                    "pitch_range": [round(lim[1][0], 1), round(lim[1][1], 1)],
                },
                "speed_max": round(self.speed_max, 1),
                "drive": self.drive,
                "limit_hit": list(self._limit_hit),
                "jog": [round(self.jog[0], 1), round(self.jog[1], 1)],
                "applied": [round(self.applied[0], 1),
                            round(self.applied[1], 1)],
                "smooth": {
                    "accel": round(self.accel, 1),
                    "predict_s": round(self.predict_s, 2),
                    "kalman": bool(self.kalman),
                    "period_ms": int(round(self.period * 1000)),
                    "deadband": round(self.track_deadband, 3),
                },
                # 双闭环：loop=vel 时 v_out/v_meas/trim/pos_err 才有意义
                "ctrl": dict(self.ctrl_info),
                "tracking": self.tracking,
                "track": dict(self.track),
                "signs": {"yaw": self.yaw_sign, "pitch": self.pitch_sign},
                "msg": self.msg,
                "error": self.last_error,
            }

    def apply(self, body):
        """处理一条控制请求。**不做任何串口 IO**，只改状态 / 入队。"""
        if not isinstance(body, dict):
            return dict(self.status(), ok=False, error="请求体不是 JSON 对象")
        if not self.available:
            return dict(self.status(), ok=False,
                        error="云台不可用: %s" % (DRIVER_ERR or "串口未配置"))
        act = str(body.get("action") or "").strip().lower()
        # ⚠ 必须用 monotonic：控制线程里的 now 也是 monotonic。
        #   早先这里用了 time.time()，epoch 值永远大于单调时钟，
        #   于是 jog_until 永远"还没到期"，点动一按就停不下来。
        now = time.monotonic()
        with self.lock:
            if act in ("", "status", "ping"):
                pass
            elif act == "jog":
                y = _num(body.get("yaw"))
                p = _num(body.get("pitch"))
                hold = _clamp(_num(body.get("hold"), self.JOG_HOLD),
                              0.15, 3.0)
                self.jog = [_clamp(y, -self.speed_max, self.speed_max),
                            _clamp(p, -self.speed_max, self.speed_max)]
                self.jog_until = now + hold
                self._want_open = True
                if self.tracking:
                    self.tracking = False
                    self.msg = "手动控制接管，已关闭追踪"
            elif act == "stop":
                self.jog = [0.0, 0.0]
                self.jog_until = 0.0
                self.msg = "已停止（角度保持）"
            elif act == "track":
                on = bool(body.get("on", True))
                if on:
                    self.tracking = True
                    self.jog = [0.0, 0.0]
                    self.jog_until = 0.0
                    self.track = {"state": "启动中…"}
                    self.msg = "追踪已开启"
                    # 重新起追踪要丢掉上一次的卡尔曼状态（目标可能已经换了）
                    self._kf_x = self._kf_y = None
                    self._kf_last_cnt = None
                    self._kf_stale = True
                else:
                    self.tracking = False
                    self._kf_x = self._kf_y = None
                    self._kf_last_cnt = None
                    self._kf_stale = True
                    self.msg = "追踪已关闭"
            elif act == "home":
                self.tracking = False
                self.jog = [0.0, 0.0]
                self.jog_until = 0.0
                self.rate_cmd = [0.0, 0.0]
                self.applied = [0.0, 0.0]
                self._tasks.append(("home", body))
                self.msg = "回零中…"
            elif act == "zero":
                mode = str(body.get("mode") or "soft").lower()
                if mode == "hw" and str(body.get("confirm") or "") != "hw-zero":
                    return dict(self.status(), ok=False,
                                error="写固件零点需要 confirm=\"hw-zero\" 二次确认")
                self.tracking = False
                self.jog = [0.0, 0.0]
                self.jog_until = 0.0
                self.rate_cmd = [0.0, 0.0]
                self.applied = [0.0, 0.0]
                self._tasks.append((("zero_hw" if mode == "hw" else "zero"), body))
                self.msg = ("写入固件零点中…" if mode == "hw" else "设置零点中…")
            elif act in ("enable", "disable", "release"):
                self._tasks.append((act, body))
            elif act == "config":
                if "speed_max" in body:
                    self.speed_max = _clamp(_num(body["speed_max"],
                                                 self.speed_max), 1.0, 90.0)
                for k in ("yaw_sign", "pitch_sign"):
                    if k in body:
                        v = 1.0 if _num(body[k], 1.0) >= 0 else -1.0
                        setattr(self, k, v)
                if "track_deadband" in body:
                    self.track_deadband = _clamp(
                        _num(body["track_deadband"], self.track_deadband),
                        0.0, 0.4)
                if "track_gain" in body:
                    self.track_gain = _clamp(
                        _num(body["track_gain"], self.track_gain), 0.2, 3.0)
                if "accel" in body:
                    self.accel = _clamp(_num(body["accel"], self.accel),
                                        10.0, 3000.0)
                if "predict_s" in body:
                    self.predict_s = _clamp(_num(body["predict_s"],
                                                 self.predict_s), 0.0, 0.6)
                if "kalman" in body:
                    self.kalman = bool(body["kalman"])
                    self._kf_x = self._kf_y = None
                    self._kf_stale = True
                if "loop" in body:
                    v = str(body["loop"]).lower()
                    self.loop = "ff" if v in ("ff", "open", "pos") else "vel"
                    self._stall = [False, False]
                if "kp_vel" in body:
                    self.kp_vel = _clamp(_num(body["kp_vel"], self.kp_vel),
                                         0.0, 2.0)
                if "lead_max" in body:
                    self.lead_max = _clamp(_num(body["lead_max"],
                                                self.lead_max), 1.0, 60.0)
                self.jog = [_clamp(self.jog[0], -self.speed_max, self.speed_max),
                            _clamp(self.jog[1], -self.speed_max, self.speed_max)]
                self._save_state()
                self.msg = "参数已更新"
            else:
                return dict(self.status(), ok=False, error="未知动作: %r" % act)
        if act in ("jog", "track", "home", "zero", "enable", "disable"):
            self._want_open = True
        self._wake.set()
        # 追踪开启时顺手把 AI 拉到"仅推理"（画面不变），必须在锁外做
        if act == "track" and bool(body.get("on", True)) and self.ai_ensure:
            try:
                note = self.ai_ensure() or ""
            except Exception as e:                       # noqa: BLE001
                note = "AI 启动失败: %s" % e
            if note:
                with self.lock:
                    self.msg = "追踪已开启（%s）" % note
        return self.status()

    # ------------------------------------------------------------------ 串口
    def _ensure_open(self):
        """打开串口并做一次"准备好"序列。返回 True/False。"""
        if self.connected:
            return True
        if not self.available:
            return False
        # 设备节点消失（USB 断开 / 供电不足重新枚举）时不要硬发命令：
        # 之前这里会读到 EIO 然后一直卡在 connected=True，页面显示"已连接"
        # 却什么都控不了（2026-10-28 实测）。
        if self.port.startswith("/") and not os.path.exists(self.port):
            self.msg = "%s 不存在（云台 USB 掉了？请重插/上电）" % self.port
            self.last_error = "no such device"
            return False
        try:
            link = Link(self.port, self.BAUD, self.REPLY_TIMEOUT)
        except Exception as e:                           # noqa: BLE001
            self.last_error = "打开 %s 失败: %s" % (self.port, e)
            self.msg = "串口打开失败（是否被官方上位机/键盘脚本占用？）"
            return False
        g = Gimbal(link)
        try:
            g.version()
            g.no_stability()            # 自稳是 IMU 世界参考，会让 ctrl angle 变味
            g.disable()
            g.diag(disabled=True)
            if not self._re_enable(g, 10):
                raise RuntimeError("使能失败（固件拒绝 enable，见 diag）")
        except Exception as e:                           # noqa: BLE001
            self.last_error = "%s" % e
            self.msg = "云台初始化失败，请检查供电/故障灯"
            try:
                link.close()
            except Exception:                            # noqa: BLE001
                pass
            return False
        self._link, self._g = link, g
        self.connected = True
        self.fw_pitch_limit = self._read_pitch_limit(g)
        self._lim = self._effective_limits()
        self.msg = "云台已连接"
        self.last_error = ""
        ok = self._read_status()
        if ok:
            self._sent = list(self.angle) if self.angle else None
            self.target = list(self.angle) if self.angle else None
        if self.verbose:
            print("[gimbal] 已连接 %s 角度=%s 固件Pitch限位=%s"
                  % (self.port, self.angle, self.fw_pitch_limit))
        return True

    def _re_enable(self, g, attempts):
        """写 Flash 之后固件会短暂回 failed: storage transaction active。"""
        for i in range(max(1, attempts)):
            try:
                g.enable()
                return True
            except Exception:                            # noqa: BLE001
                if i == 0:
                    try:
                        diag = g.diag()
                        if len(re.findall(r'enabled=1 error=0 ', diag)) == 2:
                            return True
                    except Exception:                    # noqa: BLE001
                        pass
                time.sleep(0.3)
        return False

    def _read_pitch_limit(self, g):
        """从 ``config --list`` / ``info`` 里读固件 Pitch 限位（度）。"""
        text = ""
        for cmd in ("config --list", "info"):
            try:
                text += g.link.command(cmd) + "\n"
            except Exception:                            # noqa: BLE001
                continue
        pats = (r'limit\.pitch\.deg\s*[:= ]\s*([0-9]+(?:\.[0-9]+)?)',
                r'pitch[._\s-]*deg\s*[:= ]\s*([0-9]+(?:\.[0-9]+)?)',
                r'Pitch[^\n]*?([0-9]+(?:\.[0-9]+)?)\s*(?:deg|°)')
        for pat in pats:
            m = re.search(pat, text, re.I)
            if m:
                v = _num(m.group(1))
                if 1.0 <= v <= 90.0:
                    return v
        return None

    def _read_status(self):
        """读一次 status：关节角 / 速度 / 使能。失败不影响主循环。"""
        g = self._g
        if g is None:
            return False
        try:
            reply = g.link.command('status', r'Gimbal Status:')
        except Exception as e:                           # noqa: BLE001
            self.last_error = "status 失败: %s" % e
            if _is_io_dead(e):
                self._io_dead("status 失败")
            return False
        a = re.search(_ANGLE_RE % 'Angle', reply, re.M)
        sp = re.search(_ANGLE_RE % 'Speed', reply, re.M)
        en = re.search(_ENABLED_RE, reply)
        with self.lock:
            if a:
                self.angle = [math.degrees(float(a.group(1))),
                              math.degrees(float(a.group(2)))]
                self._t_meas = time.monotonic()
            if sp:
                self.rate = [float(sp.group(1)), float(sp.group(2))]
                # Speed 是 rpm，1 rpm = 6 °/s（内环要的是 °/s）
                self._vel_meas = [self.rate[0] * 6.0, self.rate[1] * 6.0]
                for i in (0, 1):
                    if abs(self._vel_meas[i]) >= 0.5:
                        self._vel_meas_hold[i] = self._vel_meas[i]
            if en:
                self.enabled = en.group(1).lower() in ("1", "true", "yes",
                                                       "enabled", "on")
        return bool(a)

    def _close(self, why=""):
        link = self._link
        self._link = self._g = None
        self.connected = False
        self.enabled = None
        self._sent_rate = None
        if link is not None:
            try:
                link.close()
            except Exception:                            # noqa: BLE001
                pass
        if why:
            self.msg = why
        if self.verbose:
            print("[gimbal] 串口已关闭 %s" % why)

    def _io_dead(self, why=""):
        """串口已经废了（EIO / 设备消失）：断开连接，让 _loop 去重连。

        ⚠ 不能只是记一条错误就接着发：fd 失效后每次写都 EIO，
        `connected` 却还是 True，页面会一直显示“已连接”但完全失控。
        """
        try:
            if self._g is not None:
                _stop_speed(self._g)         # 万一还能发出去，先保证它停
        except Exception:                                # noqa: BLE001
            pass
        self._close("串口丢失（USB 断开/供电不足？），正在重连…")
        self.last_error = why
        with self.lock:
            self.rate_cmd = [0.0, 0.0]
            self.applied = [0.0, 0.0]
            self.jog = [0.0, 0.0]
            self.jog_until = 0.0
            if self.tracking:
                self.tracking = False
                self.msg = "追踪已停止：串口断开（正在重连）"

    # ------------------------------------------------------------------ 控制线程
    def _loop(self):
        last = time.monotonic()
        next_tel = 0.0
        fail_at = 0.0
        while not self._stop_evt.is_set():
            t_tick = time.monotonic()
            now = t_tick
            dt = now - last
            last = now
            try:
                task = None
                with self.lock:
                    if self._tasks:
                        task = self._tasks.pop(0)
                if task is not None:
                    if task[0] == "release":
                        # 释放串口：不要为了执行这个任务又把它打开
                        self._want_open = False
                        self._run_task(task)
                    else:
                        self._want_open = True
                        if self._ensure_open():
                            self._run_task(task)
                if (self._want_open and not self.connected
                        and now >= fail_at):
                    if not self._ensure_open():
                        fail_at = now + 5.0      # 失败后退避，别每拍都抢串口
                if self.connected:
                    self._tick(dt, now)
                    if now >= next_tel:
                        # ⚠ status 回显很长，一次要占 15~40ms 总线。原来固定
                        #   0.3s 一读 → 每 0.3s 指令流空一拍 → 3Hz 的「一顿」。
                        #   运动中放慢到 1s，空闲时才按 0.3s 刷（看清角度）。
                        moving = (abs(self.rate_cmd[0]) > 0.5
                                  or abs(self.rate_cmd[1]) > 0.5
                                  or self.tracking)
                        if self.drive == "speed" and self._near_limit():
                            # 贴到限位附近：软限位刹车靠"编码器角度 + 速度外推"，
                            # 推算误差 = v*age，age 越大多算越远 -> 刹车越早、
                            # 也越容易提前停。靠近限位时把回读加快到 0.15s。
                            next_tel = now + 0.15
                        else:
                            next_tel = now + (self.TELEMETRY_MOVING if moving
                                              else self.TELEMETRY)
                        self._read_status()
            except Exception as e:                       # noqa: BLE001
                self.last_error = "%s: %s" % (type(e).__name__, e)
                if self.verbose:
                    print("[gimbal] 控制异常: %s" % self.last_error)
            # 固定节拍：按"本拍开始时刻"算剩余睡眠，把串口命令的耗时抵掉。
            # 否则周期 = 周期 + 命令耗时（10~30ms 抖动），dt 忽大忽小，
            # 目标每次走的步长也跟着抖 —— 这也是"一顿一顿"的来源之一。
            spent = time.monotonic() - t_tick
            self._wake.wait(max(0.002, self.period - spent))
            self._wake.clear()

    def _near_limit(self, margin=12.0):
        """是否已贴近限位（用于加快编码器回读）。"""
        ang = self.angle
        if ang is None:
            return False
        for i in (0, 1):
            lo, hi = self._lim[i]
            if min(hi - ang[i], ang[i] - lo) < margin:
                return True
        return False

    def _freeze_rates(self):
        """把速度环彻底停住（换绝对目标前必调）。

        不这样做的话，回零/设零点时上一次点动的斜坡还没降完，
        `_tick` 会继续按残留速度把刚下发的 0° 目标往前推，
        表现为“回零回不干净、目标越跑越偏”。
        """
        with self.lock:
            self.rate_cmd = [0.0, 0.0]
            self.applied = [0.0, 0.0]
            self.jog = [0.0, 0.0]
            self.jog_until = 0.0
        self._stall = [False, False]
        self._sent_rate = None            # 逼下一拍重发（速度模式）
        self._aim_s = None                # 下一次追踪从当前 aim 重新开始

    def _run_task(self, task):
        name, body = task
        if name == "home":
            self._task_home()
        elif name == "zero":
            self._task_zero()
        elif name == "zero_hw":
            self._task_zero_hw()
        elif name == "enable":
            try:
                self._g.enable()
                self._read_status()
                self.msg = "云台已使能"
            except Exception as e:                       # noqa: BLE001
                self.last_error = "%s" % e
                self.msg = "使能失败: %s" % str(e)[:100]
        elif name == "disable":
            try:
                try:
                    self._g.speed(0, 0)
                except Exception:                        # noqa: BLE001
                    pass
                self._g.disable()
                self.target = None
                self._sent = None
                self._read_status()
                self.msg = "云台已失能（不保持位置，Pitch 可能下垂）"
            except Exception as e:                       # noqa: BLE001
                self.last_error = "%s" % e
                self.msg = "失能失败: %s" % str(e)[:100]
        elif name == "release":
            self._want_open = False
            # 速度模式下释放串口前必须发一次 0，否则云台会按最后一条速度一直转
            try:
                if self.connected and self._g is not None:
                    self._g.speed(0.0, 0.0)
            except Exception:                            # noqa: BLE001
                pass
            self._close("串口已释放（官方上位机/键盘脚本现在可以用了）")

    def _task_home(self):
        """回零点：只下发一次绝对角度目标，固件自己走完。"""
        self._freeze_rates()
        if not self._read_status() or not self.angle:
            self.msg = "回零失败：读不到关节角"
            return
        _stop_speed(self._g)          # 先退出速度模式，否则 ctrl angle 会和速度指令打架
        lo, hi = self._lim
        tgt = [_clamp(self.zero[0], lo[0], lo[1]),
               _clamp(self.zero[1], hi[0], hi[1])]
        if self._send_angle(tgt):
            self._homing_until = time.monotonic() + 25.0
            self.msg = "回零中…（目标 Yaw %.1f° Pitch %.1f°）" % (tgt[0], tgt[1])
        else:
            self.msg = "回零指令被拒绝：%s" % self.last_error

    def _task_zero(self):
        """软件零点：把当前位置记成"零"，不写固件 Flash。"""
        self._freeze_rates()
        if not self._read_status() or not self.angle:
            self.msg = "设置零点失败：读不到关节角"
            return
        self.zero = [round(self.angle[0], 2), round(self.angle[1], 2)]
        self._lim = self._effective_limits()
        self.target = list(self.angle)
        self._sent = list(self.angle)
        self._save_state()
        self.msg = ("已把当前姿态设为零点（软件零点 %.1f° / %.1f°，未写固件）"
                    % (self.zero[0], self.zero[1]))

    def _task_zero_hw(self):
        """写固件零点（config zero_pos，会保存到 Flash）。

        ⚠ 固件要求先 disable；失能后 Pitch 可能下垂，零点会按下垂后的姿态写。
          写 Flash 期间 enable 会被拒（storage transaction active），需重试。
        """
        self._freeze_rates()
        try:
            try:
                self._g.speed(0, 0)
            except Exception:                            # noqa: BLE001
                pass
            self._g.disable()
            time.sleep(0.3)
            self._g.diag(disabled=True)
            reply = self._g.zero_pos()
            text = " | ".join(x.strip() for x in reply.splitlines() if x.strip())
            ok = self._re_enable(self._g, 12)
            # 关节角被清零；机械中心保留（固件行为），所以重新读一次限位
            self.zero = [0.0, 0.0]
            self.target = None
            self._sent = None
            self._read_pitch_limit(self._g)
            self._lim = self._effective_limits()
            self._read_status()
            if self.angle:
                self.target = list(self.angle)
                self._sent = list(self.angle)
            self.msg = ("固件零点已写入%s。回显: %s"
                        % ("" if ok else "（但使能未恢复！请手动 enable）",
                           text[:160]))
        except Exception as e:                           # noqa: BLE001
            self.last_error = "%s" % e
            self.msg = "写固件零点失败: %s" % str(e)[:120]
            try:
                self._re_enable(self._g, 6)
            except Exception:                            # noqa: BLE001
                pass

    # ------------------------------------------------------------------ 每个控制拍
    def _tick(self, dt, now):
        dt = _clamp(dt, 0.0, 0.25)
        with self.lock:
            jog_on = now < self.jog_until
            jog = list(self.jog) if jog_on else [0.0, 0.0]
            tracking = self.tracking
        # ---- 0) 回零中：固件自己在走绝对角，这一拍绝不能发速度 ----
        #      回零用的是 `ctrl angle`，再发 `ctrl speed` 会把它顶掉。
        if self._homing_until:
            self._tick_home(now)
            return
        # ---- 1) 这一拍"想要"的速度 ----
        want = [0.0, 0.0]
        if tracking:
            want = self._track_rate(now) or [0.0, 0.0]
        elif jog_on:
            want = jog
        if self.drive == "speed":
            self._tick_speed(dt, now, want, jog_on, tracking)
        else:
            self._tick_angle(dt, now, want, jog_on, tracking)

    def _tick_home(self, now):
        """回零中：只判断到位/超时，不下发任何运动指令。"""
        a = self.angle
        if not a:
            return
        age = (_clamp(now - self._t_meas, 0.0, 1.2)
               if self._t_meas > 0 else 0.0)
        pos = [a[i] + self._vel_meas[i] * age for i in (0, 1)]
        if (abs(pos[0] - self.zero[0]) <= 0.8
                and abs(pos[1] - self.zero[1]) <= 0.8):
            self._homing_until = 0.0
            self._sent_rate = None          # 下一拍重发速度 0，接回连续控制
            self.target = list(self.zero)
            self._sent = list(self.zero)
            self.msg = "回零完成"
        elif now > self._homing_until:
            self._homing_until = 0.0
            self._sent_rate = None
            self.msg = "回零超时（可能被限位挡住，请看 Yaw/Pitch 读数）"

    # ---------------------------------------------------------- 连续控制（默认）
    def _tick_speed(self, dt, now, want, jog_on, tracking=False):
        """连续控制：每拍下发 **速度**（`ctrl speed`，rpm），云台一直连续转。

        与角度模式（`_tick_angle`）的差别 —— 也正是风险点：
          * 固件在速度模式下**不替你停限位**，所以这里按"刹车距离"提前收速；
          * 速度是持续输出，不再下发就**一直转** → 每 ``RATE_RESEND`` 秒重发
            一次心跳，另由 ``_guard`` 线程在控制线程卡住时强行补 0。

        控制律：``v = 前馈(追踪/点动) + 位置修正`` → 软限位刹车 → 限速 → 斜坡。

        ★ 位置修正**只在"没有前馈、且云台基本静止"时介入**（消长期漂移），
          绝不在运动/追踪时闭环。原因（2026-10-28 实测 1Hz 震荡，摆幅 27°）：
          status 最多 1s 才回读一次，`angle + vel_meas*age` 的外推误差跟运动
          状态强相关，"目标 - 推算位置" 每一秒翻一次符号 → 云台每秒反向一次。
          追踪本来就是**视觉闭环**，再叠一层延迟 1s 的位置环等于自己跟自己打架。
        """
        lim = self._lim
        ang = self.angle
        pos_est = None
        age = 0.0
        if ang is not None and self._t_meas > 0.0:
            # 编码器读数最多 1.2s 前，用实测速度前推到"现在"。
            # ⚠ 外推只给"限位/堵转"判断用，最多外推 0.4s：再长就是瞎猜。
            age = _clamp(now - self._t_meas, 0.0, 1.2)
            age_use = min(age, self.POS_EXTRAP_MAX)
            pos_est = [ang[0] + self._vel_meas[0] * age_use,
                       ang[1] + self._vel_meas[1] * age_use]

        # 目标位置 = 上一拍目标 + 本拍前馈速度 * dt（钳在限位里）
        tgt = list(self.target) if self.target else list(ang or [0.0, 0.0])
        for i in (0, 1):
            lo, hi = lim[i]
            tgt[i] = _clamp(tgt[i] + want[i] * dt, lo, hi)

        # ★ 前馈（点动/追踪）刚结束的那一拍：把目标直接对齐到实测位置。
        #   否则“目标”是点动期间积分出来的（含 JOG_HOLD 尾巴），位置环会去追它。
        feed = bool(jog_on or tracking)
        if self._feed_prev and not feed:
            ref = pos_est if pos_est is not None else ang
            if ref is not None:
                for i in (0, 1):
                    lo, hi = lim[i]
                    tgt[i] = _clamp(ref[i], lo, hi)
        self._feed_prev = feed

        v = [want[0], want[1]]
        stall = [False, False]
        # 什么时候允许位置环介入：没有前馈 + 两轴都几乎不动
        calm = (abs(want[0]) < 0.2 and abs(want[1]) < 0.2
                and abs(self._vel_meas[0]) <= 3.0
                and abs(self._vel_meas[1]) <= 3.0)
        pos_fb = bool(not tracking and calm)
        if pos_est is not None:
            gain = self.kp_vel * _clamp(1.0 - age / 1.2, 0.0, 1.0)
            for i in (0, 1):
                lead = tgt[i] - pos_est[i]
                # 堵转保护：目标超前实测太多就不再推进（免得放开后猛冲）
                #   追踪时只有"真的转不动"才冻结 —— 否则会打断视觉闭环
                if (abs(lead) > self.lead_max
                        and (lead > 0) == (want[i] > 0) and abs(want[i]) > 0.5
                        and ((not tracking) or abs(self._vel_meas[i]) < 0.5)):
                    stall[i] = True
                    tgt[i] = _clamp(pos_est[i]
                                    + math.copysign(self.lead_max, lead),
                                    lim[i][0], lim[i][1])
                    lead = tgt[i] - pos_est[i]
                if pos_fb:
                    # 静止微调：**带死区**。没超过死区一律不出力（否则就是
                    # “松手后自己慢慢转”）；超过了才按超出的部分纠正，最多 1°/s。
                    ex = lead
                    if abs(ex) > self.POS_FB_TOL:
                        ex -= math.copysign(self.POS_FB_TOL, ex)
                        v[i] += _clamp(ex * gain, -self.POS_FB_MAX,
                                       self.POS_FB_MAX)

        # ---- 软限位刹车：剩多远 = 到限位的余量 - 刹车距离 ----
        #   刹车距离 = v²/(2a)。到限位前提前收速，速度连续降到 0，
        #   既不会越界（不像"撞到限位再停"那种硬碰），也不会突然断掉。
        for i in (0, 1):
            lo, hi = lim[i]
            base = pos_est[i] if pos_est is not None else tgt[i]
            brake = v[i] * abs(v[i]) / (2.0 * max(1.0, self.accel))
            if v[i] > 0.0:
                room = hi - base - brake
                if room <= 0.5:
                    v[i] = 0.0
                    self._limit_hit[i] = True
                elif room < 3.0:
                    v[i] = min(v[i], max(0.3, room))
                    self._limit_hit[i] = True
                else:
                    self._limit_hit[i] = False
            elif v[i] < 0.0:
                room = base - lo - brake
                if room <= 0.5:
                    v[i] = 0.0
                    self._limit_hit[i] = True
                elif room < 3.0:
                    v[i] = max(v[i], -max(0.3, room))
                    self._limit_hit[i] = True
                else:
                    self._limit_hit[i] = False
            v[i] = _clamp(v[i], -self.speed_max, self.speed_max)

        # ---- 加速度斜坡：速度连续变化，云台就不会"起步/到点/松手"一顿 ----
        acc = self.accel * dt
        cur = list(self.rate_cmd)
        for i in (0, 1):
            d = v[i] - cur[i]
            if d > acc:
                cur[i] += acc
            elif d < -acc:
                cur[i] -= acc
            else:
                cur[i] = v[i]
            if abs(cur[i]) < 0.05:
                cur[i] = 0.0
        with self.lock:
            self.rate_cmd = cur
            self.applied = [round(cur[0], 2), round(cur[1], 2)]
            self.target = list(tgt)
            self._stall = list(stall)
            if not jog_on:
                self.jog = [0.0, 0.0]
            self.ctrl_info = {
                "loop": "speed",
                "v_cmd": [round(cur[0], 1), round(cur[1], 1)],
                "v_want": [round(v[0], 1), round(v[1], 1)],
                "v_meas": [round(self._vel_meas[0], 1),
                           round(self._vel_meas[1], 1)],
                "lead": ([round(tgt[0] - self.angle[0], 2),
                          round(tgt[1] - self.angle[1], 2)]
                         if self.angle else None),
                "stall": list(stall),
                "limit_hit": list(self._limit_hit),
                "pos_fb": pos_fb,
                "age_ms": (int((now - self._t_meas) * 1000)
                           if self._t_meas > 0 else None),
            }
        self._send_rate(cur)

    def _send_rate(self, rate_deg_s, force=False):
        """下发速度指令：`ctrl speed`，单位 **rpm**（1 rpm = 6°/s）。

        变化 > 0.02 rpm 就发；另外每 ``RATE_RESEND`` 秒无条件重发一次 ——
        既是"心跳"（丢命令/固件复位后能自愈），也是看门狗的时间基准。
        """
        g = self._g
        if g is None:
            return False
        rpm = [rate_deg_s[0] / 6.0, rate_deg_s[1] / 6.0]
        prev = self._sent_rate
        now = time.monotonic()
        need = (force or prev is None
                or abs(rpm[0] - prev[0]) > 0.02
                or abs(rpm[1] - prev[1]) > 0.02
                or (now - self._t_cmd) >= self.RATE_RESEND)
        if not need:
            return True
        try:
            g.speed(rpm[0], rpm[1])
        except Exception as e:                           # noqa: BLE001
            self.last_error = "速度指令被拒绝: %s" % e
            self._sent_rate = None
            self._t_cmd = 0.0
            if _is_io_dead(e):
                # 串口真的坏了：关掉连接，交给 _loop 重连（带 5s 退避）
                self._io_dead("速度指令失败")
                return False
            with self.lock:
                self.rate_cmd = [0.0, 0.0]
                self.applied = [0.0, 0.0]
                self.jog = [0.0, 0.0]
                self.jog_until = 0.0
                if self.tracking:
                    self.tracking = False
                    self.msg = "追踪已停止：速度指令被拒绝（%s）" % str(e)[:90]
                else:
                    self.msg = "速度指令被拒绝（%s）" % str(e)[:90]
            return False
        self._sent_rate = rpm
        self._t_cmd = now
        return True

    # ---------------------------------------------------------- 步进控制（回退用）
    def _tick_angle(self, dt, now, want, jog_on, tracking):
        # ---- 2) 斜坡（加速度限幅）：这是"不顿"的关键 ----
        #   原来 0 -> 25°/s 是阶跃，目标一步跳 1.5°，固件到点就停；
        #   现在每拍最多变 accel*dt（默认 250°/s² → 25ms 里 6.25°/s），
        #   速度连续变化，云台就不会"起步一顿、到点一顿、松手一顿"。
        acc = self.accel * dt
        cur = list(self.rate_cmd)
        for i in (0, 1):
            d = want[i] - cur[i]
            if d > acc:
                cur[i] += acc
            elif d < -acc:
                cur[i] -= acc
            else:
                cur[i] = want[i]
            if abs(cur[i]) < 0.05:
                cur[i] = 0.0          # 防止无限逼近 0 的残余抖动
        with self.lock:
            self.rate_cmd = cur
            self.applied = [round(cur[0], 2), round(cur[1], 2)]
            if not jog_on:
                self.jog = [0.0, 0.0]
        lim = self._lim
        tgt = list(self.target) if self.target else None
        if tgt is None:
            return
        # ---- 3) 外环（位置环）+ 防积分饱和 ----
        #   编码器最多 1 s 才读一次，所以这里只做两件**慢**事：
        #   a) 堵转/跟不上保护：目标超前实测超过 lead_max 就**不再加码**，
        #      等云台跟上来。正常跟随时超前只有零点几度，这条根本不触发；
        #      云台被挡住时目标也不会一直往前堆（否则放开后要猛冲一大段）。
        #   b) 慢速/静止时把目标朝编码器角度修，限速 2°/s：
        #      消掉长期漂移，又不会把正在进行的运动拽出节奏。
        pos_ok = (self.loop == "vel" and self.angle is not None
                  and self._t_meas > 0.0 and (now - self._t_meas) < 2.0
                  and not self._homing_until and not tracking)
        for i in (0, 1):
            nv = tgt[i] + cur[i] * dt
            self._stall[i] = False
            if pos_ok:
                # 编码器读数可能已经旧了 1s，先按实测速度推算到现在再比 ——
                # 否则“正常在跑”也会被当成“超前太多”，目标就被冻住了。
                age = _clamp(now - self._t_meas, 0.0, 1.2)
                pos_est = self.angle[i] + self._vel_meas[i] * age
                lead = nv - pos_est
                # 同方向且超前太多 -> 云台没跟上
                if (abs(lead) > self.lead_max
                        and (lead > 0) == (cur[i] > 0) and abs(cur[i]) > 0.5):
                    nv = tgt[i]                 # 原地等，目标不再往前跑
                    self._stall[i] = True
                elif abs(cur[i]) <= 3.0:
                    err = self.angle[i] - nv
                    if abs(err) > 0.3:
                        nv += _clamp(err * self.kp_vel, -2.0, 2.0) * dt
            lo, hi = lim[i]
            tgt[i] = _clamp(nv, lo, hi)
        with self.lock:
            self.ctrl_info = {
                "loop": self.loop,
                "v_cmd": [round(cur[0], 1), round(cur[1], 1)],
                "v_meas": [round(self._vel_meas[0], 1),
                           round(self._vel_meas[1], 1)],
                "lead": ([round(tgt[0] - self.angle[0], 2),
                          round(tgt[1] - self.angle[1], 2)]
                         if self.angle else None),
                "stall": list(self._stall),
                "age_ms": (int((now - self._t_meas) * 1000)
                           if self._t_meas > 0 else None),
            }
        # 目标要立刻记回对象里：不发指令的那些拍也必须保留累加结果，
        # 否则下一拍又从旧目标算起，低速永远走不动。
        with self.lock:
            self.target = list(tgt)
        # 只在"相对上次**已下发**的目标"变化超过 0.02° 时才发指令。
        # ⚠ 必须始终累加到 tgt、只拿 _sent 比较：早先写法是"变化小于阈值就不
        #   更新 tgt"，低速(0.5°/s → 每拍 0.0125°)时永远凑不满阈值，目标就
        #   再也不动了（追踪收尾卡在差 0.7° 上）。
        send = (self._sent is None
                or abs(tgt[0] - self._sent[0]) > 0.02
                or abs(tgt[1] - self._sent[1]) > 0.02)
        if send:
            self._send_angle(tgt)
        # 空闲时对齐：被别的工具/手搬动过 -> 目标跟着实测走，避免"回头猛跑"
        # ⚠ 回零过程中走不到这里（回零由 _tick 提前 return 给 _tick_home），
        #   否则会把刚下发的 0° 目标改成"当前位置"，云台走两步就停在半路。
        if (not send and not tracking and not jog_on
                and self.angle and self.target):
            if (abs(self.angle[0] - self.target[0]) > 8.0
                    or abs(self.angle[1] - self.target[1]) > 8.0):
                with self.lock:
                    self.target = list(self.angle)
                    self._sent = list(self.angle)

    def _send_angle(self, tgt):
        lo, hi = self._lim
        t = [_clamp(tgt[0], lo[0], lo[1]), _clamp(tgt[1], hi[0], hi[1])]
        try:
            self._g.angle(math.radians(t[0]), math.radians(t[1]))
        except Exception as e:                           # noqa: BLE001
            self.last_error = "%s" % e
            with self.lock:
                if self._sent:
                    self.target = list(self._sent)
                self.jog = [0.0, 0.0]
                self.jog_until = 0.0
                if self.tracking:
                    self.tracking = False
                    self.msg = "追踪已停止：运动指令被拒绝（%s）" % str(e)[:90]
                else:
                    self.msg = "运动指令被拒绝（%s）" % str(e)[:90]
            return False
        with self.lock:
            self.target = list(t)
            self._sent = list(t)
            self.last_error = ""
        return True

    # ------------------------------------------------------------------ 追踪
    def _track_rate(self, now):
        """按 YOLO **最大目标**算云台角速度（度/秒），带卡尔曼预测。

        处理链：
          框中心 → 归一化误差(±1) → **一维匀速卡尔曼**（位置+速度）
          → 按速度外推 ``predict_s`` 秒（补 AI+串口的流水线延迟）
          → 比例律给小速度，死区只防静座微颤
        返回本拍"想要"的角速度，再交给 ``_tick`` 做加速度限幅。

        方向由 ``yaw_sign`` / ``pitch_sign`` 决定（默认与 gimbal_keyctrl.py
        的键位观察一致：画面里的目标往右 → Yaw 发负速度；目标偏上 →
        Pitch 发正速度）。
        """
        ai = None
        if self.ai_status is not None:
            try:
                ai = self.ai_status()
            except Exception as e:                       # noqa: BLE001
                self.track = {"state": "AI 状态读取失败: %s" % e}
                return [0.0, 0.0]
        if not ai:
            self.track = {"state": "AI 未启用（服务没加 --ai）", "rate": [0, 0]}
            return [0.0, 0.0]
        if not ai.get("active"):
            self.track = {"state": "AI 已关闭（追踪需要「仅推理」或「标注」）",
                          "rate": [0, 0]}
            return [0.0, 0.0]
        dets = ai.get("detections") or []
        fw, fh = 0, 0
        fr = ai.get("frame") or []
        if isinstance(fr, (list, tuple)) and len(fr) >= 2:
            fw, fh = int(fr[0] or 0), int(fr[1] or 0)
        if not dets:
            # 目标丢失：卡尔曼跟着停（不再外推），速度交给 _tick 斜坡降下来
            self.track = {"state": "未检测到目标", "persons": 0, "rate": [0, 0]}
            self._kf_stale = True
            self._aim_s = None           # 重新出现时不要从旧瞄准点滑过去
            return [0.0, 0.0]
        if fw <= 0 or fh <= 0:
            self.track = {"state": "AI 未给出画面尺寸", "persons": len(dets),
                          "rate": [0, 0]}
            return [0.0, 0.0]

        def _box4(d):
            """取四元组，兼容 None / numpy 数组 / 长度不足。"""
            try:
                b = [float(v) for v in (d.get("box") or [])]
            except Exception:                            # noqa: BLE001
                b = []
            return b if len(b) >= 4 else [0.0, 0.0, 0.0, 0.0]

        def area(d):
            b = _box4(d)
            return max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])

        best = max(dets, key=area)
        x1, y1, x2, y2 = _box4(best)
        cx, cy = (x1 + x2) / 2.0, (y1 + y2) / 2.0
        # 瞄准点：ai_overlay 按"云台试探位移能不能全包"选出来的
        #   能全包 -> 人体几何中心（头脚中点）
        #   装不下 -> 头部中心；头被上边框裁掉才退回框中心
        # 老版本没有 aim 字段就退回框中心。
        aim = best.get("aim")
        if isinstance(aim, (list, tuple)) and len(aim) >= 2:
            try:
                cx, cy = float(aim[0]), float(aim[1])
            except (TypeError, ValueError):
                pass
        # aim 点做一阶低通：head <-> 几何中心 在临界处会来回切，
        # 直接给误差会让云台"点头"。40Hz 下 k=0.5 ≈ 30ms 时间常数。
        if self._aim_s is None:
            self._aim_s = [cx, cy]
        else:
            k = 0.5
            self._aim_s[0] += (cx - self._aim_s[0]) * k
            self._aim_s[1] += (cy - self._aim_s[1]) * k
            cx, cy = self._aim_s
        aim_head = bool(best.get("aim_head"))
        aim_mode = best.get("aim_mode") or ("头部" if aim_head else "身体")
        can_full = best.get("can_full")
        ex = (cx - fw / 2.0) / (fw / 2.0)
        ey = (cy - fh / 2.0) / (fh / 2.0)

        # ---- 只在"确实有新推理结果"时才喂卡尔曼 ----
        #   AI 30fps、控制 40Hz，同一个框会连续读到两次；重复测量会把速度
        #   估计压成 0（过平滑），所以用 infer_count 做闸门。
        cnt = ai.get("infer_count")
        dt_ai = 0.033
        if self._kf_last_cnt is None:
            dt_ai = 0.05
        elif cnt is not None:
            if cnt == self._kf_last_cnt:
                # 没有新结果 -> 只做预测（外推），不 update
                if self.kalman and self._kf_x is not None:
                    self._kf_x.predict(min(0.1, max(0.005, self.period)))
                    self._kf_y.predict(min(0.1, max(0.005, self.period)))
            else:
                d_cnt = max(1, int(cnt) - int(self._kf_last_cnt))
                dt_ai = _clamp(d_cnt / max(1.0, float(ai.get("fps") or 30.0)),
                               0.008, 0.5)
        self._kf_last_cnt = cnt

        if self.kalman:
            if self._kf_x is None or self._kf_y is None or self._kf_stale:
                self._kf_x = _KalmanCV(self.kf_r, self.kf_q)
                self._kf_y = _KalmanCV(self.kf_r, self.kf_q)
                self._kf_x.reset(ex)
                self._kf_y.reset(ey)
                self._kf_stale = False
            ex_s, vy = self._kf_x.update(ex, dt_ai)
            ey_s, vp = self._kf_y.update(ey, dt_ai)
            # 前瞻 = 设定值 + 这一帧结果已经过时多久（age_ms）。
            # 串口/固件执行还要再等 ~10~30ms，所以总和一般比 age 略大。
            age = _clamp(_num(ai.get("age_ms"), 0.0) / 1000.0, 0.0, 0.3)
            ahead = _clamp(self.predict_s + age, 0.0, 0.6)
            ex_p = self._kf_x.pos_at(ahead)
            ey_p = self._kf_y.pos_at(ahead)
        else:
            ex_s, ey_s, vy, vp = ex, ey, 0.0, 0.0
            ex_p, ey_p = ex, ey
            ahead = 0.0

        dead = self.track_deadband

        def axis_rate(err, vmax):
            if abs(err) <= dead:
                return 0.0
            mag = min(1.0, (abs(err) - dead) / max(1e-6, self.track_full - dead))
            return -mag * vmax * (1.0 if err > 0 else -1.0)

        r_yaw = (self.yaw_sign * self.track_gain
                 * axis_rate(ex_p, self.speed_max))
        r_pit = (self.pitch_sign * self.track_gain
                 * axis_rate(ey_p, min(self.speed_max, 15.0)))
        # 「已对准」看的是预测误差，不看"速度是否恰好为 0"：
        # 误差落进死区边缘时会算出 0.05°/s 这种非零速度，按速度判会永远显示"追踪中"。
        aligned = (abs(ex_p) <= dead * 2.5 and abs(ey_p) <= dead * 2.5)
        self.track = {
            "state": "已对准" if aligned else "追踪中",
            "persons": len(dets),
            "tid": best.get("tid"),
            "score": best.get("score"),
            "box": [int(x1), int(y1), int(x2), int(y2)],
            "aim": [int(round(cx)), int(round(cy))],
            "aim_mode": aim_mode,
            "can_full": (bool(can_full) if can_full is not None else None),
            "est_h": best.get("est_h"),
            "full": bool(best.get("full")),
            "frame": [fw, fh],
            "err": [round(ex, 3), round(ey, 3)],          # 原始测量
            "err_kf": [round(ex_s, 3), round(ey_s, 3)],   # 滤波后
            "vel": [round(vy, 2), round(vp, 2)],          # 归一化速度 (1/s)
            "err_pred": [round(ex_p, 3), round(ey_p, 3)],
            "predict_s": round(self.predict_s, 2),
            "ahead_s": round(ahead, 2),
            "kalman": bool(self.kalman),
            "rate": [round(r_yaw, 1), round(r_pit, 1)],
            "yaw_deg": _round(self.angle[0] if self.angle else None),
            "pitch_deg": _round(self.angle[1] if self.angle else None),
        }
        return [r_yaw, r_pit]
