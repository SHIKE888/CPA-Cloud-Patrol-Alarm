# -*- coding: utf-8 -*-
"""车端状态直连：通过 rosbridge 订阅底盘话题（目前只用 /PowerVoltage）。

为什么自己实现 WebSocket
------------------------
板上 python 3.8 没有 `websocket-client` / `websockets` / `roslibpy`
（实测三个都没有），而这条链路只用到「文本帧 + JSON」两件事。
为一个电压值去改环境装依赖不划算：装包要联网，板上断网就部署不了。
所以这里用标准库 socket 自己握手 + 编解码，不到 200 行，零依赖。

数据来源（源码已确认）
----------------------
turn_on_wheeltec_robot/src/wheeltec_robot.cpp:160  Publish_Voltage()
  → 从底盘串口读电源电压 → 发布 /PowerVoltage (std_msgs/Float32, 单位 V, 约每 11 个循环一次)
底盘驱动没起时这个话题不存在，本模块会一直重连并报告 online=False。

用法
----
    cl = CarLink("ws://192.168.100.87:9090")
    cl.start()                 # 后台线程，自动重连
    cl.snapshot()              # {"online":bool,"voltage":..,"pct":..,"age":..,"err":..}
"""

import base64
import json
import os
import socket
import struct
import threading
import time
from urllib.parse import urlparse

TOPIC = "/PowerVoltage"
TOPIC_TYPE = "std_msgs/Float32"


# ---------------------------------------------------------------- 电压 -> 电量
def volt_to_pct(v, v_full=25.0, v_empty=20.0):
    """电压(V) 换算成电量百分比。

    曲线来自轮趣官方 Qt 工具（qt_ros_test/src/main_window.cpp:358）：
        24V 系统：25V -> 100%，20V -> 0%，中间线性；18~20V 记 0%；>25V 记 100%。
        12V 系统：12.5V -> 100%，10V -> 0%。
    这里补了厂家公式的一个空档：原文 `>25 -> 100`、`<24 && >=20 -> 线性`，
    24.0 ≤ V ≤ 25.0 两个分支都不命中，进度条会停在旧值不动。改成 >=24 直接 100%。

    注意：这是**厂家的经验曲线**，不是真实 SOC（锂电池中段电压很平）。
    """
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    if v <= 0:
        return None
    if v >= 24.0:                      # 含 24~25 那段空档
        return 100
    if v >= v_empty:
        return int(round((1.0 - (v_full - v) / (v_full - v_empty)) * 100))
    if v >= 18.0:                      # 厂家：<20 且 >18 记 0%
        return 0
    # ---- 12V 系统 ----
    if v > 12.5:
        return 100
    if v >= 10.0:
        return int(round((1.0 - (12.5 - v) / 2.5) * 100))
    return 0


# ---------------------------------------------------------------- 极简 WS 客户端
class _WS(object):
    """只够用：文本帧、单帧消息、客户端掩码、支持 126/127 长度。"""

    def __init__(self, url, timeout=6.0):
        u = urlparse(url)
        self.host = u.hostname or "127.0.0.1"
        self.port = int(u.port or 80)
        self.path = u.path or "/"
        self.sock = socket.create_connection((self.host, self.port), timeout=timeout)
        self.sock.settimeout(timeout)
        self._buf = b""
        self._handshake()

    def _handshake(self):
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET %s HTTP/1.1\r\n"
               "Host: %s:%d\r\n"
               "Upgrade: websocket\r\n"
               "Connection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n"
               "\r\n" % (self.path, self.host, self.port, key))
        self.sock.sendall(req.encode())
        # 读到 \r\n\r\n 为止（注意多读的字节要留进 buffer）
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError("握手时连接被关闭")
            data += chunk
        head, _, rest = data.partition(b"\r\n\r\n")
        self._buf = rest
        first = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        if "101" not in first:
            raise IOError("握手失败: %s" % first)

    def send_text(self, text):
        payload = text.encode("utf-8")
        n = len(payload)
        head = b"\x81"                       # FIN + text
        mask = os.urandom(4)
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(payload[i] ^ mask[i % 4] for i in range(n))
        self.sock.sendall(head + mask + masked)

    def _need(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise IOError("连接被关闭")
            self._buf += chunk

    def recv_text(self):
        """返回一条文本消息；控制帧（ping/pong/close）内部处理掉。"""
        while True:
            self._need(2)
            b1, b2 = self._buf[0], self._buf[1]
            opcode = b1 & 0x0F
            masked = b2 & 0x80
            n = b2 & 0x7F
            off = 2
            if n == 126:
                self._need(4)
                n = struct.unpack(">H", self._buf[2:4])[0]
                off = 4
            elif n == 127:
                self._need(10)
                n = struct.unpack(">Q", self._buf[2:10])[0]
                off = 10
            if masked:
                self._need(off + 4)
                mask = self._buf[off:off + 4]
                off += 4
            self._need(off + n)
            payload = self._buf[off:off + n]
            self._buf = self._buf[off + n:]
            if masked:
                payload = bytes(payload[i] ^ mask[i % 4] for i in range(n))
            if opcode == 0x1:                 # text
                return payload.decode("utf-8", "replace")
            if opcode == 0x8:                 # close
                raise IOError("对端关闭连接")
            if opcode == 0x9:                 # ping -> pong
                self.sock.sendall(b"\x8A\x80" + os.urandom(4))
                continue
            # 0x0 连续帧 / 0xA pong 等都忽略：rosbridge 的消息是单帧
            continue

    def close(self):
        try:
            self.sock.close()
        except Exception:                                    # noqa: BLE001
            pass


# ---------------------------------------------------------------- 对外接口
class CarLink(object):
    def __init__(self, url="ws://192.168.100.87:9090", reconnect_s=5.0,
                 stale_s=12.0):
        self.url = url
        self.reconnect_s = float(reconnect_s)
        self.stale_s = float(stale_s)         # 超过这么久没收到 = 视为离线
        self._lock = threading.Lock()
        self._voltage = None
        self._ts = 0.0
        self._err = "尚未连接"
        self._online = False
        self._stop = threading.Event()
        self._thr = None

    # ---- 生命周期
    def start(self):
        if self._thr and self._thr.is_alive():
            return
        self._stop.clear()
        self._thr = threading.Thread(target=self._run, name="car-link",
                                     daemon=True)
        self._thr.start()

    def stop(self):
        self._stop.set()
        t = self._thr
        if t and t.is_alive():
            t.join(timeout=2.0)

    # ---- 对外快照
    def snapshot(self):
        with self._lock:
            v, ts, err, on = self._voltage, self._ts, self._err, self._online
        now = time.time()
        age = round(now - ts, 1) if ts else None
        if on and age is not None and age > self.stale_s:
            on = False
            err = "超过 %.0fs 没收到 %s" % (self.stale_s, TOPIC)
        return {
            "online": bool(on),
            "topic": TOPIC,
            "voltage": (round(v, 2) if isinstance(v, (int, float)) else None),
            "pct": volt_to_pct(v) if isinstance(v, (int, float)) else None,
            "age": age,
            "err": "" if on else err,
            "url": self.url,
        }

    # ---- 内部
    def _set(self, **kw):
        with self._lock:
            for k, v in kw.items():
                setattr(self, "_" + k, v)

    def _run(self):
        while not self._stop.is_set():
            ws = None
            try:
                ws = _WS(self.url, timeout=6.0)
                ws.send_text(json.dumps(
                    {"op": "subscribe", "topic": TOPIC, "type": TOPIC_TYPE}))
                self._set(err="已连接，等待 %s …" % TOPIC)
                ws.sock.settimeout(2.0)      # 轮转，便于响应 stop
                while not self._stop.is_set():
                    try:
                        txt = ws.recv_text()
                    except socket.timeout:
                        continue
                    try:
                        msg = json.loads(txt)
                    except ValueError:
                        continue
                    if msg.get("op") != "publish":
                        # rosbridge 会先回 subscribe 状态等，忽略即可
                        if msg.get("op") == "status" and msg.get("level") == "error":
                            self._set(err="rosbridge: %s" % msg.get("msg"))
                        continue
                    if msg.get("topic") != TOPIC:
                        continue
                    data = (msg.get("msg") or {}).get("data")
                    if isinstance(data, (int, float)) and data > 0:
                        self._set(voltage=float(data), ts=time.time(),
                                  online=True, err="")
            except Exception as e:                           # noqa: BLE001
                self._set(online=False, err="%s: %s" % (type(e).__name__, e))
            finally:
                if ws is not None:
                    ws.close()
            if self._stop.is_set():
                break
            time.sleep(self.reconnect_s)


if __name__ == "__main__":                # 手工自检：python3 car_link.py [ws地址]
    import sys
    cl = CarLink(sys.argv[1] if len(sys.argv) > 1 else "ws://192.168.100.87:9090")
    cl.start()
    for _ in range(10):
        time.sleep(1.0)
        s = cl.snapshot()
        print("%s  online=%s  V=%s  pct=%s  err=%s"
              % (time.strftime("%H:%M:%S"), s["online"], s["voltage"],
                 s["pct"], s["err"]))
    cl.stop()
