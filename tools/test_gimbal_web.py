# -*- coding: utf-8 -*-
"""gimbal_web.py 核心回归（离线，不需要板子/真串口）。

用一个假的 ``gimbal_keyctrl`` 顶替串口：它按真实固件的口径回话，
并按 ``ctrl angle``（绝对角，到点停）或 ``ctrl speed``（rpm，持续转）移动关节。

覆盖的都是出过事的地方：
  1) 连上后能读到角度 / 固件 Pitch 限位；
  2) 点动 hold 到期自动停；
  3) 速度模式下**软限位不越界**（速度模式固件不限位，全靠软件）；
  4) 看门狗：控制线程卡住 0.6s -> 独立线程补发 `ctrl speed 0 0`；
  5) 不自激：编码器 10Hz 回读时速度指令不能周期性反向（2026-10-28 的 1Hz 震荡）；
  6) 串口 EIO（USB 掉线）要断开重连，不能假装 connected。

跑法： python tools/test_gimbal_web.py
"""
from __future__ import annotations

import math
import os
import sys
import threading
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.abspath(os.path.join(HERE, "..", "rk", "web"))
if WEB not in sys.path:
    sys.path.insert(0, WEB)

FAIL = []


class FakeLink(object):
    def __init__(self, port, baud, timeout):
        if port != "fake":
            raise OSError("no such port")
        self.port = port
        self.closed = False
        self.gimbal = None
        self.fd = None                 # 看门狗测试用（换成管道写端）

    def command(self, cmd, expect=None):
        g = self.gimbal
        if g is None:
            raise RuntimeError("no gimbal")
        low = cmd.strip().lower()
        if low == "version":
            return "Firmware target Run 2.0.2-dm_mc2.8\nQGimbal:/$ "
        if low == "info":
            return "Axis CAN1/Yaw CAN2/Pitch  IMU ready\nPitch limit 30 deg\n"
        if low == "config --list":
            return "limit.pitch.deg = 30.0000\nlimit.speed = 50\nQGimbal:/$ "
        if low == "status":
            g.advance()
            j, r = g.joint, g.rate
            return ("Gimbal Status:\n  Enabled: %s\n"
                    "  Angle: yaw:%.6f rad, pitch:%.6f rad\n"
                    "  Speed: yaw:%.6f rpm, pitch:%.6f rpm\nQGimbal:/$ "
                    % ("yes" if g.enabled else "no",
                       math.radians(j[0]), math.radians(j[1]), r[0], r[1]))
        if low == "enable":
            g.enabled = True
            return "QGimbal enabled\nQGimbal:/$ "
        if low == "disable":
            g.enabled = False
            g.rate = [0.0, 0.0]
            return "QGimbal disabled\nQGimbal:/$ "
        if low == "disable_stability":
            return "stability control disabled\nQGimbal:/$ "
        if low == "diag":
            e = 1 if g.enabled else 0
            return ("Target=Run Fault=0 Owner=USB IMU_ready=1\n"
                    "enabled=%d error=0 a\nenabled=%d error=0 b\nQGimbal:/$ "
                    % (e, e))
        if low.startswith("ctrl angle"):
            if not g.enabled:
                raise RuntimeError("failed: disable first")
            part = low.split()
            g.set_angle(math.degrees(float(part[2])),
                        math.degrees(float(part[3])))
            return "Setting control\nQGimbal:/$ "
        if low.startswith("ctrl speed"):
            part = low.split()
            g.set_speed(float(part[2]), float(part[3]))
            return "Setting control\nQGimbal:/$ "
        if low == "config zero_pos":
            g.zero_writes += 1
            g.joint = [0.0, 0.0]
            g.target = [0.0, 0.0]
            return "Zero position set\nQGimbal:/$ "
        raise RuntimeError("Command not Found")

    def close(self):
        self.closed = True


class FakeGimbal(object):
    """关节角按模式运动；上报的 Speed 是**实际**角速度（rpm）。"""

    TURN = 200.0      # 度/秒（角度模式的追赶上限）

    def __init__(self, link):
        link.gimbal = self
        self.link = link
        self.enabled = False
        self.joint = [0.0, 0.0]
        self.target = [0.0, 0.0]
        self.rate = [0.0, 0.0]
        self.mode = "angle"
        self.zero_writes = 0
        self._t = time.time()

    def advance(self):
        now = time.time()
        dt = max(1e-4, now - self._t)
        self._t = now
        step = self.TURN * dt
        j0 = list(self.joint)
        for i in (0, 1):
            if self.mode == "speed":
                want = self.rate[i] * 6.0 * dt        # rpm -> °/s
                self.joint[i] += max(-step, min(step, want))
                self.target[i] = self.joint[i]
            else:
                d = self.target[i] - self.joint[i]
                if abs(d) <= step:
                    self.joint[i] = self.target[i]
                else:
                    self.joint[i] += math.copysign(step, d)
        self.rate = [(self.joint[i] - j0[i]) / dt / 6.0 for i in (0, 1)]

    # --- 与 gimbal_keyctrl.Gimbal 同名 ---
    def version(self):
        return self.link.command("version")

    def enable(self):
        return self.link.command("enable")

    def disable(self):
        return self.link.command("disable")

    def no_stability(self):
        return self.link.command("disable_stability")

    def diag(self, disabled=False):
        return self.link.command("diag")

    def speed(self, y, p):
        self.advance()
        self.mode = "speed"
        self.rate = [float(y), float(p)]
        return "Setting control"

    def zero_pos(self):
        return self.link.command("config zero_pos")

    def set_angle(self, yaw_deg, pitch_deg):
        self.advance()
        self.mode = "angle"
        self.rate = [0.0, 0.0]
        self.target = [yaw_deg, pitch_deg]

    def set_speed(self, y_rpm, p_rpm):
        self.advance()
        self.mode = "speed"
        self.rate = [y_rpm, p_rpm]

    def angle(self, yaw_rad, pitch_rad):       # GimbalWeb 调这个
        self.set_angle(math.degrees(yaw_rad), math.degrees(pitch_rad))
        return "Setting control"


fake_mod = types.ModuleType("gimbal_keyctrl")
fake_mod.Link = FakeLink
fake_mod.Gimbal = FakeGimbal
sys.modules["gimbal_keyctrl"] = fake_mod

import gimbal_web                                             # noqa: E402

assert gimbal_web.Link is FakeLink, "假模块没被采用"

LINKS = []
_orig_init = FakeLink.__init__


def _init(self, port, baud, timeout):
    _orig_init(self, port, baud, timeout)
    LINKS.append(self)


FakeLink.__init__ = _init


def check(name, cond, detail=""):
    print("  [%s] %s %s" % ("PASS" if cond else "FAIL", name, detail))
    if not cond:
        FAIL.append(name)


def wait(cond, timeout=8.0, step=0.05):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if cond():
            return True
        time.sleep(step)
    return False


def make(drive="speed", **kw):
    g = gimbal_web.GimbalWeb(port="fake", yaw_limit_deg=170.0,
                             pitch_limit_deg=42.0, speed_max=25.0,
                             state_path=None, verbose=False, drive=drive, **kw)
    g.start()
    g._want_open = True
    wait(lambda: g.connected, 5.0)
    return g


def main():
    print("1) 连接 / 初始化")
    g = make()
    st = g.status()
    check("串口已连接", st["connected"] is True, st["msg"])
    check("读到关节角", st["yaw_deg"] is not None, str(st["yaw_deg"]))
    check("读到固件 Pitch 限位 30°", st["limits"]["pitch_fw"] == 30.0,
          str(st["limits"]["pitch_fw"]))
    check("Pitch 绝对限位收窄到 29°", st["limits"]["pitch_abs"] == 29.0,
          str(st["limits"]["pitch_abs"]))
    check("驱动方式 = speed", st["drive"] == "speed", st["drive"])
    # 回读耗时是在控制线程的定时分支里统计的，连上后等一拍才有值
    check("上报姿态回读耗时",
          wait(lambda: g.status()["telemetry_ms"] is not None, 3.0),
          str(g.status()["telemetry_ms"]))

    print("2) 点动 + hold 到期自动停")
    g.apply({"action": "jog", "yaw": 20.0, "pitch": 0.0, "hold": 0.6})
    time.sleep(0.4)
    t1 = list(g.status()["target"] or [0, 0])
    check("按住时在走", abs(t1[0]) > 2.0, "target=%s" % t1)
    time.sleep(1.0)
    t2 = list(g.status()["target"] or [0, 0])
    time.sleep(0.6)
    t3 = list(g.status()["target"] or [0, 0])
    check("hold 到期后自动停", abs(t3[0] - t2[0]) < 0.8, "%s -> %s" % (t2, t3))

    print("3) 速度模式软限位不越界")
    g.apply({"action": "config", "speed_max": 40.0, "accel": 400.0})
    end = time.time() + 14.0
    worst = 0.0
    while time.time() < end:
        g.apply({"action": "jog", "yaw": 40.0, "pitch": 0.0, "hold": 1.0})
        time.sleep(0.2)
        worst = max(worst, g.status()["yaw_deg"] or 0.0)
    g.apply({"action": "stop"})
    check("Yaw 不越 170.5°", worst <= 170.5, "最大 %.1f°" % worst)
    check("到位后速度归零",
          wait(lambda: abs(g.status()["applied"][0]) < 0.3, 4.0),
          str(g.status()["applied"]))
    g.stop()

    print("4) 看门狗：控制线程卡住时独立补发 ctrl speed 0 0")
    time.sleep(0.3)
    g2 = make()
    fake = LINKS[-1].gimbal
    r_fd, w_fd = os.pipe()
    os.set_blocking(r_fd, False)
    try:
        g2.stop()                       # 控制线程停掉 = 模拟卡死
        time.sleep(0.3)
        g2._stop_evt = threading.Event()
        fake.link.fd = w_fd
        fake.mode = "speed"
        fake.rate = [3.0, 0.0]
        g2._sent_rate = [3.0, 0.0]
        g2._t_cmd = time.monotonic() - 5.0
        th = threading.Thread(target=g2._guard, daemon=True)
        th.start()
        time.sleep(0.5)
        try:
            got = os.read(r_fd, 4096).decode("ascii", "replace")
        except (BlockingIOError, OSError):
            got = ""
        check("看门狗补发 0", "ctrl speed 0 0" in got, repr(got))
        g2._stop_evt.set()
    finally:
        fake.link.fd = None
        os.close(r_fd)
        os.close(w_fd)
    g2.stop()

    print("5) 不自激：编码器 10Hz 回读，速度指令不能周期性反向")
    time.sleep(0.3)
    g3 = make()
    LINKS[-1].gimbal.joint = [0.0, 0.0]
    LINKS[-1].gimbal.target = [0.0, 0.0]
    g3.apply({"action": "jog", "yaw": 25.0, "pitch": 0.0, "hold": 4.0})
    signs = []
    t_end = time.time() + 2.5
    while time.time() < t_end:
        v = (g3.status().get("ctrl") or {}).get("v_cmd") or [0.0]
        if abs(v[0]) >= 1.0:
            signs.append(1 if v[0] > 0 else -1)
        time.sleep(0.05)
    g3.apply({"action": "stop"})
    flips = sum(1 for a, b in zip(signs, signs[1:]) if a != b)
    check("同向指令期间不反向", flips == 0, "翻转 %d 次 / %d 采样" % (flips, len(signs)))

    print("6) 串口 EIO 要断开重连，不能假装 connected")
    check("OSError 判为链路已死",
          gimbal_web._is_io_dead(OSError(5, "Input/output error")))
    check("固件拒绝不当作链路已死",
          not gimbal_web._is_io_dead(RuntimeError("enable 被拒绝: failed")))
    g3._io_dead("模拟 EIO")
    st = g3.status()
    check("_io_dead 断开连接", st["connected"] is False, st["msg"])
    check("清掉残余速度", st["applied"] == [0.0, 0.0], str(st["applied"]))
    g3.stop()

    print()
    if FAIL:
        print("FAILED: %s" % ", ".join(FAIL))
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
