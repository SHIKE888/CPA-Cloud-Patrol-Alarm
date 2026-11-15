# -*- coding: utf-8 -*-
"""串口四色指示灯 + 蜂鸣器驱动（Modbus-RTU）

协议来源: docs/串口四色指示灯通讯协议2025版.pdf
  串口   : 9600 8N1 无校验
  协议   : Modbus-RTU，模块 ID = 0x01
  帧格式 : 01 05 00 <reg> <state> 00 <CRC_L> <CRC_H>
    reg   : 01 红 / 02 绿 / 03 蓝 / 04 黄
            05 蜂鸣器
            06 红+蜂鸣 / 07 绿+蜂鸣 / 08 蓝+蜂鸣 / 09 黄+蜂鸣
            0A 全部关 + 蜂鸣关
    state : 00 关 / 01 常亮(常响) / 02 慢闪(慢响) / 03 快闪(快响) / 04 暴闪(暴响)

⚠ 说明书表头那行 `01 05 00 01 01 00 15 9A` 的 CRC 是笔误（正解 9D 9A），
  这里一律用标准 Modbus CRC16 自己算，并在启动时用文档里的 3 组样例自检。

状态机（业务含义，由 mipi_webstream 的报警逻辑喂进来）:
  boot     上电中          蓝灯常亮
  normal   正常运行        绿灯常亮
  person   画面里有人员    黄灯快闪
  intrude  人员进警戒区    黄灯快闪（立即，不等阈值）
  danger   出现危险动作    红灯快闪，保持 danger_hold_s 秒后回落到其它状态
  intrude5s 越界持续满 N 秒 红灯快闪，一直保持到人离开警戒区

设计要点:
  · **串口唯一写者**：本类独占一个串口线程，外部只改内存里的输入量，
    照抄 gimbal_web.py 的做法，避免多线程抢同一个 fd。
  · **硬件缺失自动降级**：串口打不开时只更新状态、不抛异常，每 5s 重试 打开。
    这样即使灯没插，整个视频/报警链路也不受影响。
  · **只在状态变化时下发**，避免 20Hz 刷串口。
"""

import os
import threading
import time

try:
    import serial
except Exception:                                        # noqa: BLE001
    serial = None

try:
    import usb.core as _usb_core
    import usb.util as _usb_util
except Exception:                                        # noqa: BLE001
    _usb_core = None
    _usb_util = None


# ---------------------------------------------------------------- Modbus CRC
def modbus_crc16(data):
    """标准 Modbus RTU CRC16（poly 0xA001，初值 0xFFFF）。"""
    crc = 0xFFFF
    for b in bytearray(data):
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc & 0xFFFF


# 文档里的样例（reg, state, CRC 两个字节），启动时自检用
_CRC_SAMPLES = [
    ((0x01, 0x00), (0x9C, 0x0A)),   # 关闭红色
    ((0x01, 0x01), (0x9D, 0x9A)),   # 打开红色
    ((0x0A, 0x00), (0xED, 0xC8)),   # 全部灯关闭 + 蜂鸣关
    ((0x03, 0x04), (0x3F, 0x0A)),   # 蓝色暴闪
]


def _selfcheck_crc():
    for (reg, st), (lo, hi) in _CRC_SAMPLES:
        body = bytes([0x01, 0x05, 0x00, reg, st, 0x00])
        crc = modbus_crc16(body)
        if (crc & 0xFF, (crc >> 8) & 0xFF) != (lo, hi):
            return False, (reg, st, "want %02X %02X got %02X %02X"
                           % (lo, hi, crc & 0xFF, (crc >> 8) & 0xFF))
    return True, ""


# ---------------------------------------------------------------- 灯状态表
#  状态名 -> (颜色, 灯态)
#  灯态: 0 关 / 1 常亮 / 2 慢闪 / 3 快闪 / 4 暴闪
STATE_LAMP = {
    # 2026-11-16 用户要求（分两段）：
    #   boot     = 刚上电、云台还没动  -> 蓝灯**常亮**
    #   bootmove = 云台开始动（自检执行中）-> 蓝灯**慢闪**
    #   自检结束 -> 转绿（green 长亮）。
    # 两段分开是因为"通了电"和"真的在动作"是两件事，闪/不闪本身就是进度。
    "boot":     ("blue",   1),      # 上电待机：蓝灯常亮
    "bootmove": ("blue",   2),      # 云台自检动作中：蓝灯慢闪
    "normal":   ("green",  1),      # 正常：绿灯长亮
    "person":   ("yellow", 1),      # 仅识别到人员（不在警戒区）：黄灯长亮
    "intrude":  ("yellow", 3),      # 进入警戒区（立即）：黄灯快闪
    "danger":   ("red",    3),      # 危险动作：红灯快闪
    "intrude5s": ("red",   3),      # 越界持续满 N 秒：红灯快闪
}

# 纯色灯寄存器 / 灯+蜂鸣联动寄存器
REG_LAMP = {"red": 0x01, "green": 0x02, "blue": 0x03, "yellow": 0x04}
REG_LAMP_BUZZ = {"red": 0x06, "green": 0x07, "blue": 0x08, "yellow": 0x09}
REG_BUZZER = 0x05
REG_ALL_OFF = 0x0A

# 需要鸣叫的状态：**只有红灯**（危险动作 / 越界满 N 秒）。
# 黄灯（仅检测到人、进入警戒区）保持静音 —— 用户要求"只在红灯亮时快速滴滴"，
# 否则一进画面就一直响。蜂鸣总开关关掉时全部静音。
_STATES_WITH_SOUND = ("danger", "intrude5s")


class _NoCh340(Exception):
    """总线上没有 CH340 设备（不是错误，只是这条通路不适用）。"""


class Ch340Port(object):
    """用户态 CH340/CH341 串口。

    为什么需要它：本板内核 `CONFIG_USB_SERIAL_CH341 is not set`，也没有
    ch341.ko 可加载。可以用 sysfs `new_id` 把 CH340 硬绑到 `usbserial_generic`
    上、生成 /dev/ttyUSB0，**但 generic 驱动不实现 CH341 私有控制请求，
    波特率根本设不进去** —— 于是出现"能 open、能 write、灯就是不响应"这种
    最难查的假象。所以 CH340 一律走用户态驱动，自己按 ch341.c 的 vendor
    请求把波特率/线路参数写进芯片。

    设备被内核驱动占用时用 pyusb 的 detach_kernel_driver 抢过来
    （本内核裁掉了 driver 的 bind/unbind sysfs 属性，sysfs 那条路走不通）。

    只支持 9600/115200 等 ch341.c 里有固定分频值的速率 —— 灯只需要 9600。
    """

    VID, PID = 0x1A86, 0x7523
    EP_OUT, EP_IN = 0x02, 0x82
    LCR_8N1 = 0xC3                  # ENABLE_RX|ENABLE_TX|CS8
    _BAUD = {
        2400:   (0xD901, 0x0038),
        4800:   (0x6402, 0x001F),
        9600:   (0xB202, 0x0013),
        19200:  (0xD902, 0x000D),
        38400:  (0x6403, 0x000A),
        115200: (0xCC03, 0x0008),
    }

    def __init__(self, baud=9600):
        if _usb_core is None or _usb_util is None:
            raise IOError("pyusb 未安装")
        dev = _usb_core.find(idVendor=self.VID, idProduct=self.PID)
        if dev is None:
            raise _NoCh340()
        self.dev = dev
        if dev.is_kernel_driver_active(0):
            dev.detach_kernel_driver(0)
        _usb_util.claim_interface(dev, 0)
        self._init_chip(int(baud))

    def _co(self, req, val, idx):
        self.dev.ctrl_transfer(0x40, req, val, idx, None, 1000)

    def _ci(self, req, val, idx, n):
        return self.dev.ctrl_transfer(0xC0, req, val, idx, n, 1000)

    def _init_chip(self, baud):
        try:                                   # 读 2 字节版本，失败不影响后续
            self._ci(0x5F, 0, 0, 2)
        except Exception:                      # noqa: BLE001
            pass
        self._co(0xA1, 0x0000, 0x0000)
        self._co(0xA1, 0x501F, 0xD90A)
        a, b = self._BAUD.get(baud, self._BAUD[9600])
        self._co(0x9A, 0x1312, a)              # 波特率低 16 位
        self._co(0x9A, 0x0F2C, b)              # 波特率高位/预分频
        self._co(0x9A, 0x2518, self.LCR_8N1)   # 8 数据位 / 1 停止位 / 无校验
        self._co(0xA4, 0xFF, 0x0000)           # 握手(DTR/RTS 都放开)
        self.baud = baud

    # ---- 与 pyserial 对齐的最小接口 ----
    def write(self, data):
        self.dev.write(self.EP_OUT, data, timeout=1000)
        return len(data)

    def flush(self):
        pass

    def read(self, n):
        try:
            return bytes(self.dev.read(self.EP_IN, n, timeout=200))
        except Exception:                      # noqa: BLE001
            return b""

    def close(self):
        for fn in (lambda: _usb_util.release_interface(self.dev, 0),
                   lambda: _usb_util.dispose_resources(self.dev)):
            try:
                fn()
            except Exception:                  # noqa: BLE001
                pass


class AlarmLight(object):
    """四色灯 + 蜂鸣器。所有对外方法都是线程安全的。"""

    def __init__(self, port=None, baud=9600, module_id=0x01,
                 reopen_s=5.0, tick_s=0.05,
                 danger_hold_s=5.0, intrude_alarm_s=5.0):
        self.port = port or os.environ.get("LAMP_PORT") or "/dev/ttyUSB0"
        self.baud = int(baud)
        self.mid = int(module_id) & 0xFF
        self.reopen_s = float(reopen_s)
        self.tick_s = float(tick_s)
        # 危险动作红灯保持时长；越界满多少秒升级红灯
        self.danger_hold_s = float(danger_hold_s)
        self.intrude_alarm_s = float(intrude_alarm_s)

        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thr = None

        # ---- 输入量（由外部 feed） ----
        self._persons = 0
        self._in_zone = False
        self._in_zone_since = None
        self._danger_until = 0.0

        self._buzzer_on = False           # 用户开关（默认关）

        # ---- 内部状态 ----
        # 蓝灯（boot）不再固定几秒：上电时 udev 会先点亮一次，服务接管后继续蓝着，
        # 直到**云台自检结束 + 画面真的出来了**（mipi_webstream 的 lamp-feed 线程
        # 两个条件都满足才调 boot_done()）。2026-11-16 用户要求自检期间蓝灯闪。
        # _boot_until 只是兜底：万一 boot_done 永远没来，最多蓝 5 分钟转正常。
        # 5 分钟是因为自检本身最长约 90~120s（串口等 30s + 回零 60s + 摆动），
        # 原来 120s 会在自检还没完就把蓝灯提前切走。
        self._boot_until = time.time() + 300.0
        self._boot_motion = False         # 云台是否已开始动作（决定蓝灯常亮/慢闪）
        self._boot_done = False
        self._state = None
        self._sent = None                 # 最近一次成功下发的 (reg, state)
        self._ser = None
        self._last_open_try = 0.0
        self._err = ""
        self._ok_ever = False
        self._tx = 0
        self._rx = 0
        self._crc_ok, self._crc_err = _selfcheck_crc()

    # ------------------------------------------------------------ 生命周期
    def start(self):
        if self._thr and self._thr.is_alive():
            return
        self._stop.clear()
        self._thr = threading.Thread(target=self._run, name="alarm-light",
                                     daemon=True)
        self._thr.start()

    def stop(self):
        self._stop.set()
        t = self._thr
        if t and t.is_alive():
            t.join(timeout=1.0)
        self._close()

    # ------------------------------------------------------------ 外部输入
    def feed(self, persons=None, in_zone=None, danger=False, intrude_s=None):
        """喂入实时状态。全部可选，只覆盖显式传入的项。

        persons   : 画面中的人数（int）
        in_zone   : 是否有人位于警戒区内（bool）
        danger    : 本次调用是否检测到危险动作（True 会重置保持计时）
        intrude_s : 越界升级红灯的阈值秒数（可运行时改）
        """
        now = time.time()
        with self._lock:
            if intrude_s is not None:
                try:
                    self.intrude_alarm_s = max(0.0, float(intrude_s))
                except (TypeError, ValueError):
                    pass
            if persons is not None:
                try:
                    self._persons = max(0, int(persons))
                except (TypeError, ValueError):
                    pass
            if in_zone is not None:
                iz = bool(in_zone)
                if iz and not self._in_zone:
                    self._in_zone_since = now
                elif not iz:
                    self._in_zone_since = None
                self._in_zone = iz
            if danger:
                self._danger_until = now + self.danger_hold_s

    def boot_done(self):
        """启动完成：结束蓝灯，进入正常运行状态（绿/黄/红）。"""
        with self._lock:
            self._boot_done = True

    def boot_motion(self, on):
        """云台是否正在动作：True -> 蓝灯慢闪，False -> 蓝灯常亮（仅 boot 阶段有效）。

        2026-11-16 用户要求：上电时蓝灯常亮，云台一开始运动才闪。
        """
        with self._lock:
            self._boot_motion = bool(on)

    def set_buzzer(self, on):
        with self._lock:
            self._buzzer_on = bool(on)
            return self._buzzer_on

    def toggle_buzzer(self):
        with self._lock:
            self._buzzer_on = not self._buzzer_on
            return self._buzzer_on

    # ------------------------------------------------------------ 输出状态
    def snapshot(self):
        with self._lock:
            now = time.time()
            st = self._state or self._compute_state(now)
            return {
                "ok": self._ok_ever and not self._err,
                "port": self.port,
                "open": self._ser is not None,
                "err": self._err,
                "state": st,
                "persons": self._persons,
                "in_zone": self._in_zone,
                "in_zone_s": (round(now - self._in_zone_since, 1)
                              if self._in_zone_since else 0.0),
                "danger_left_s": round(max(0.0, self._danger_until - now), 1),
                "buzzer": self._buzzer_on,
                "crc_selftest": self._crc_ok,
                "tx": self._tx,
                "rx": self._rx,
            }

    # ------------------------------------------------------------ 状态机
    def _compute_state(self, now):
        """把输入量折算成灯状态。优先级：boot > danger > intrude5s > intrude/person > normal。"""
        if not self._boot_done and now < self._boot_until:
            # 上电待机蓝灯常亮；云台开始动作（自检）时转慢闪
            return "bootmove" if self._boot_motion else "boot"
        # 1) 危险动作：红灯快闪，保持 danger_hold_s
        if now < self._danger_until:
            return "danger"
        # 2) 越界持续满 N 秒：红灯快闪，直到人离开
        if self._in_zone and self._in_zone_since is not None:
            if (now - self._in_zone_since) >= self.intrude_alarm_s:
                return "intrude5s"
            return "intrude"
        # 3) 画面里有人：黄灯快闪
        if self._persons > 0:
            return "person"
        return "normal"

    # ------------------------------------------------------------ 串口线程
    def _run(self):
        while not self._stop.is_set():
            now = time.time()
            with self._lock:
                st = self._compute_state(now)
                self._state = st
                buz = self._buzzer_on
                in_snd = st in _STATES_WITH_SOUND
            try:
                self._apply(st, buz and in_snd, now)
            except Exception as e:                        # noqa: BLE001
                with self._lock:
                    self._err = "apply: %s" % e
                self._close()
            self._stop.wait(self.tick_s)

    def _apply(self, st, sound, now):
        color, lamp = STATE_LAMP.get(st, ("green", 1))
        if sound:
            reg = REG_LAMP_BUZZ[color]
        else:
            reg = REG_LAMP[color]
        want = (reg, lamp)
        if want == self._sent:
            return
        if self._ser is None:
            if now - self._last_open_try < self.reopen_s:
                return
            self._last_open_try = now
            if not self._open():
                return
        # 先全灭再点目标：避免上一个颜色的灯还亮着（四色灯是独立通道）。
        # 2026-11-16：灯态变化（常亮 <-> 慢闪）也先灭一次 —— 蓝灯要在
        # "上电常亮" 和 "云台动作时慢闪" 之间切换，有的模块只在
        # "灭 -> 点亮" 时重新解析闪烁模式，直接改值可能仍按常亮走。
        if self._sent is not None and self._sent != want:
            self._write(REG_ALL_OFF, 0x00)
        self._write(reg, lamp)
        self._sent = want

    # ------------------------------------------------------------ 串口 I/O
    def _open(self):
        # 1) CH340 优先走**用户态**驱动。
        #    本内核能用 usbserial_generic 给它 /dev/ttyUSB0，也能 open/write，
        #    但不实现 CH341 私有控制请求 -> 波特率永远是上电默认值，
        #    表现为“不报错、但灯完全不动”，比打不开难查得多。
        errs = []
        if _usb_core is not None:
            try:
                self._ser = Ch340Port(self.baud)
                with self._lock:
                    self._err = ""
                    self._ok_ever = True
                    self._sent = None      # 重连后必须重发一次
                return True
            except _NoCh340:
                pass                       # 没插 CH340，继续走标准 tty
            except Exception as e:         # noqa: BLE001
                errs.append("CH340 用户态: %s" % e)

        # 2) 标准 tty（CP2102 / FTDI / PL2303 等内核原生支持的模块）
        if serial is None:
            errs.append("pyserial 未安装")
        elif not os.path.exists(self.port):
            errs.append("设备不存在: %s" % self.port)
        else:
            try:
                self._ser = serial.Serial(self.port, self.baud, timeout=0.15,
                                          write_timeout=0.3)
                with self._lock:
                    self._err = ""
                    self._ok_ever = True
                    self._sent = None
                return True
            except Exception as e:         # noqa: BLE001
                errs.append("打开 %s 失败: %s" % (self.port, e))

        with self._lock:
            self._err = "; ".join(errs) or "无可用串口"
        self._ser = None
        return False

    def _close(self):
        s, self._ser = self._ser, None
        if s is not None:
            try:
                s.close()
            except Exception:                             # noqa: BLE001
                pass
        with self._lock:
            self._sent = None

    def _frame(self, reg, state):
        body = bytes([self.mid, 0x05, 0x00, reg & 0xFF, state & 0xFF, 0x00])
        crc = modbus_crc16(body)
        return body + bytes([crc & 0xFF, (crc >> 8) & 0xFF])

    def _write(self, reg, state):
        if self._ser is None:
            return False
        frame = self._frame(reg, state)
        try:
            self._ser.write(frame)
            self._ser.flush()
            with self._lock:
                self._tx += 1
            # Modbus 0x05 会原样回显 8 字节，读回来能确认模块真收到了
            try:
                back = self._ser.read(len(frame))
            except Exception:                             # noqa: BLE001
                back = b""
            if back:
                with self._lock:
                    self._rx += 1
                if back != frame:
                    with self._lock:
                        self._err = "回显不一致: %s != %s" % (
                            back.hex(" "), frame.hex(" "))
            return True
        except Exception as e:                            # noqa: BLE001
            with self._lock:
                self._err = "写失败: %s" % e
            self._close()
            return False
