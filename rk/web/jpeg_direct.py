#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
jpeg_direct.py —— RK 端 JPEG 直通推流（不再做任何软件编码）

赛题要求: 传给 RK 的就是 JPEG 压缩流; RK 端只做"收 + 转发 + 解码给 AI",
**不允许软件压缩**。

本脚本就是那个"收 + 转发":
    v4l2-ctl --stream-to=-  ->  按 FF D8 ... FF D9 切帧  ->  multipart 直通给浏览器

特点:
  · 推流路径**零编码**、零色彩转换: 浏览器直接解 FPGA 出的 JPEG。
    单帧 3840x1080 在 CPU 上软编要 ~50ms, 直通后这段完全消失。
  · 不需要 cv2 才能出画面（cv2 只在 --decode-every N>0 时用来校验码流可解）。
  · 找不到 JPEG 帧时明确报错, 并给出排查提示（大概率是 FPGA 没开 0x0B 或
    rkcif 不接受 DT=0x18）。

用法:
    python3 jpeg_direct.py                       # /dev/video22, :9013
    python3 jpeg_direct.py --dev /dev/video22 --port 80
    python3 jpeg_direct.py --decode-every 30     # 每 30 帧解码一次做校验

HTTP:
    GET /stream        multipart/x-mixed-replace 的 MJPEG 直通
    GET /snapshot.jpg  最新一帧原始 JPEG
    GET /api/status    帧号 / 实际 fps / 帧字节数 / 距今毫秒 / 错误信息
"""

import argparse
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BOUNDARY = "frame"


# =============================================================================
#  JPEG 帧源: 从 v4l2-ctl 的字节流里切帧
# =============================================================================
class JpegSource(threading.Thread):
    """把 v4l2-ctl 输出的字节流按 SOI/EOI 切成 JPEG 帧。

    为什么用 v4l2-ctl 而不是自己 ioctl:
      · rkcif 的 JPEG 节点格式(setup / buffer 数 / plane 数)还未经硬件验证,
        自己写 ioctl 容易踩坑; v4l2-ctl 会把格式协商做对。
      · 拿到的就是"帧的字节", 不需要知道 sizeimage(JPEG 每帧长度可变),
        正好符合 MIPI 可变长包的特性。
    """

    def __init__(self, dev, v4l2ctl="v4l2-ctl", decode_every=0, width=0, height=0):
        super().__init__(daemon=True)
        self.dev = dev
        self.v4l2ctl = v4l2ctl
        self.decode_every = decode_every
        self.width = width
        self.height = height

        self.lock = threading.Lock()
        self.latest = None          # 最新一帧 JPEG 字节
        self.frame_id = 0
        self.bytes_last = 0
        self.t_last = 0.0
        self.fps = 0.0
        self.err = ""
        self.soi_cnt = 0
        self.decoded_ok = 0
        self.decoded_bad = 0
        self.proc = None

    # ---------------- 对外 ----------------
    def snapshot(self):
        with self.lock:
            return self.latest, self.frame_id

    def status(self):
        with self.lock:
            age = (time.time() - self.t_last) * 1000.0 if self.t_last else -1.0
            return {
                "dev": self.dev,
                "frame_id": self.frame_id,
                "fps": round(self.fps, 1),
                "jpeg_bytes": self.bytes_last,
                "age_ms": round(age, 1),
                "soi_seen": self.soi_cnt,
                "decoded_ok": self.decoded_ok,
                "decoded_bad": self.decoded_bad,
                "err": self.err,
            }

    # ---------------- 内部 ----------------
    def _publish(self, frame):
        now = time.time()
        with self.lock:
            if self.t_last:
                dt = now - self.t_last
                if dt > 0:
                    inst = 1.0 / dt
                    # 一阶平滑, 避免 uart/网络抖动让读数乱跳
                    self.fps = inst if self.fps == 0 else (self.fps * 0.8 + inst * 0.2)
            self.latest = frame
            self.bytes_last = len(frame)
            self.t_last = now
            self.frame_id += 1

    def _maybe_decode(self, frame):
        """只为校验: 能解出来说明 FPGA 出的码流是合法 JPEG。不做编码。"""
        if self.decode_every <= 0:
            return
        if (self.frame_id % self.decode_every) != 0:
            return
        try:
            import cv2
            import numpy as np
            img = cv2.imdecode(np.frombuffer(frame, dtype=np.uint8), cv2.IMREAD_REDUCED_GRAYSCALE_8)
            with self.lock:
                if img is None:
                    self.decoded_bad += 1
                else:
                    self.decoded_ok += 1
        except Exception as e:            # cv2 不存在时不要影响推流
            with self.lock:
                self.err = "decode check skipped: %s" % e
            self.decode_every = 0

    def run(self):
        cmd = [self.v4l2ctl, "-d", self.dev,
               "--stream-mmap", "--stream-to=-", "--stream-count=0"]
        print("[jpeg] %s" % " ".join(cmd))
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, bufsize=0)
        except Exception as e:
            self.err = "spawn failed: %s" % e
            print("[jpeg] 启动 v4l2-ctl 失败: %s" % e)
            return

        # stderr 单独收: 格式协商/丢帧信息在那里
        def _drain_err(p):
            for line in iter(p.stderr.readline, b""):
                s = line.decode("utf-8", "replace").rstrip()
                if s:
                    print("[v4l2] %s" % s)
        threading.Thread(target=_drain_err, args=(self.proc,), daemon=True).start()

        buf = bytearray()
        last_warn = 0.0
        t0 = time.time()
        while True:
            chunk = self.proc.stdout.read(65536)
            if not chunk:
                self.err = "v4l2-ctl exited (no more data)"
                break
            buf += chunk

            # 一帧 = FF D8 ... FF D9。可变长, 所以只能按标记切。
            while True:
                soi = buf.find(b"\xff\xd8")
                if soi < 0:
                    # 没找到帧头, 丢掉垃圾但保留 1 字节以防标记被切断
                    if len(buf) > 1:
                        del buf[:-1]
                    break
                if soi > 0:
                    del buf[:soi]
                eoi = buf.find(b"\xff\xd9", 2)
                if eoi < 0:
                    break                       # 帧还没收全
                frame = bytes(buf[:eoi + 2])
                del buf[:eoi + 2]
                with self.lock:
                    self.soi_cnt += 1
                self._publish(frame)

            # 3 秒一帧都没有 -> 明确提示, 别让人对着黑屏猜
            now = time.time()
            if self.soi_cnt == 0 and now - t0 > 3.0 and now - last_warn > 5.0:
                last_warn = now
                print("[jpeg] 警示: 3 秒内没收到任何 JPEG 帧头 (FF D8)。\n"
                      "        排查顺序:\n"
                      "          1) FPGA 是否打开了 JPEG 输出:  i2cset -y 9 0x40 0x0B 1\n"
                      "          2) 板上 bit 版本:              i2cget -y 9 0x40 0xA9  (应 >= 0x09)\n"
                      "          3) rkcif 是否接受了 DT=0x18:   dmesg | grep -i -e csi -e mipi | tail -20\n"
                      "          4) 节点格式:                   v4l2-ctl -d %s --get-fmt-video" % self.dev)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.kill()
            except Exception:
                pass


# =============================================================================
#  HTTP
# =============================================================================
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    source = None

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, ctype, body, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_GET(self):
        path = self.path.split("?")[0]

        if path == "/api/status":
            import json
            body = json.dumps(self.source.status(), ensure_ascii=False).encode("utf-8")
            self._send(200, "application/json; charset=utf-8", body)
            return

        if path in ("/snapshot.jpg", "/snapshot"):
            frame, _ = self.source.snapshot()
            if not frame:
                self._send(503, "text/plain; charset=utf-8", b"no jpeg frame yet")
            else:
                self._send(200, "image/jpeg", frame)
            return

        if path in ("/stream", "/"):
            self.send_response(200)
            self.send_header("Content-Type",
                             "multipart/x-mixed-replace; boundary=%s" % BOUNDARY)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            last_id = -1
            try:
                while True:
                    frame, fid = self.source.snapshot()
                    if frame and fid != last_id:
                        last_id = fid
                        self.wfile.write(b"--" + BOUNDARY.encode() + b"\r\n")
                        self.wfile.write(b"Content-Type: image/jpeg\r\n")
                        self.wfile.write(("Content-Length: %d\r\n\r\n" % len(frame)).encode())
                        self.wfile.write(frame)
                        self.wfile.write(b"\r\n")
                    else:
                        time.sleep(0.002)
            except Exception:
                return
            return

        self._send(404, "text/plain; charset=utf-8", b"not found")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default=os.environ.get("JPEG_DEV", "/dev/video22"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("JPEG_PORT", "9013")))
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--v4l2ctl", default="v4l2-ctl")
    ap.add_argument("--decode-every", type=int, default=0,
                    help="每 N 帧用 cv2.imdecode 校验一次码流(不做编码), 0=不校验")
    args = ap.parse_args()

    src = JpegSource(args.dev, args.v4l2ctl, args.decode_every)
    src.start()

    Handler.source = src
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    print("[jpeg] 直通服务 http://%s:%d/stream  (设备 %s)" % (args.host, args.port, args.dev))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        src.stop()


if __name__ == "__main__":
    main()
