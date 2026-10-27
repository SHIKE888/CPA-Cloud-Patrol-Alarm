#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""板端 A/B: 软件 cv2 JPEG vs RK MPP 硬件 JPEG 的单帧往返耗时。

目的: 回答「为什么开了硬件编码延时反而变大」。
只做测量, 不改任何文件 / 不碰运行中的 mipi-webstream (只读它的 /snapshot.jpg 当素材)。

硬件路径完全按 mipi_webstream.HwJpegEncoder 的方式跑:
    gst-launch-1.0 -q fdsrc fd=0 blocksize=<frame> ! rawvideoparse format=nv12
                    width=W height=H ! mppjpegenc ! fdsink fd=1
写入 -> 从 stdout 读回一个 FF D8..FF D9, 这一整段就是「一帧的硬编往返时延」。
"""
import json
import queue
import subprocess
import sys
import threading
import time
import urllib.request

import cv2
import numpy as np

W, H = 1920, 1080
N = 20


def get_frame():
    for url in ("http://127.0.0.1:9012/snapshot.jpg",
                "http://127.0.0.1/snapshot.jpg"):
        try:
            b = urllib.request.urlopen(url, timeout=5).read()
            im = cv2.imdecode(np.frombuffer(b, np.uint8), cv2.IMREAD_COLOR)
            if im is not None:
                print("素材: %s  %dx%d %d B" % (url, im.shape[1], im.shape[0], len(b)))
                return cv2.resize(im, (W, H))
        except Exception as e:                                     # noqa: BLE001
            print("取帧失败 %s: %s" % (url, e))
    # 兜底: 合成一张有纹理的图
    print("素材: 合成图")
    im = np.zeros((H, W, 3), np.uint8)
    im[:] = (60, 90, 120)
    for i in range(0, H, 20):
        im[i:i + 8, :] = (200, 180, 40)
    return im


def bgr_to_y_uv(img):
    """BGR -> 4:2:2 的 Y 平面 + 全高 UV 交织平面 (板子源格式就是 NV16)。"""
    yuv = cv2.cvtColor(img, cv2.COLOR_BGR2YUV_I420).reshape(-1)
    y = yuv[:W * H].reshape(H, W)
    u = yuv[W * H:W * H + W * H // 4].reshape(H // 2, W // 2)
    v = yuv[W * H + W * H // 4:].reshape(H // 2, W // 2)
    uv = np.empty((H, W // 2, 2), np.uint8)
    uv[0::2, :, 0] = u
    uv[0::2, :, 1] = v
    uv[1::2, :, 0] = u
    uv[1::2, :, 1] = v
    return y, uv


def nv12_to_nv16(raw):
    """生产代码里 _nv12_scaled 的等价动作 (NV16 源 -> 转 NV12/拷成 bytes)。"""
    wh = W * H
    buf = np.frombuffer(raw, np.uint8)
    y = buf[:wh].reshape(H, W)
    c = buf[wh:wh * 2].reshape(H, W // 2, 2)
    c12 = np.ascontiguousarray(c[::2])
    out = np.concatenate([y.reshape(-1), c12.reshape(-1)])
    return out.tobytes()


class HwEnc:
    def __init__(self):
        self.fb = W * H * 3 // 2
        cmd = ["gst-launch-1.0", "-q",
               "fdsrc", "fd=0", "blocksize=%d" % self.fb, "!",
               "rawvideoparse", "format=nv12", "width=%d" % W,
               "height=%d" % H, "!",
               "mppjpegenc", "!", "fdsink", "fd=1"]
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, bufsize=0)
        self.q = queue.Queue()
        self.buf = bytearray()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            d = self.p.stdout.read(65536)
            if not d:
                break
            self.buf.extend(d)
            while True:
                s = self.buf.find(b"\xff\xd8")
                if s < 0:
                    break
                e = self.buf.find(b"\xff\xd9", s + 2)
                if e < 0:
                    break
                self.q.put(bytes(self.buf[s:e + 2]))
                del self.buf[:e + 2]
        self.q.put(None)

    def encode(self, data, timeout=2.0):
        mv = memoryview(data)
        while mv:
            n = self.p.stdin.write(mv)
            if not n:
                return None
            mv = mv[n:]
        try:
            return self.q.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self):
        try:
            self.p.kill()
        except Exception:                                          # noqa: BLE001
            pass


def stats(v):
    a = np.array(v, float)
    return "avg %.2f ms  min %.2f  max %.2f" % (a.mean(), a.min(), a.max())


def main():
    img = get_frame()
    y, uv = bgr_to_y_uv(img)
    nv16 = np.concatenate([y.reshape(-1), uv.reshape(-1)]).tobytes()  # 源格式
    nv12 = nv12_to_nv16(nv16)                                        # 硬编喂的格式

    print("\n=== 1) NV16 -> 转 NV12/拷 bytes (_nv12_scaled 等价) ===")
    t = []
    for _ in range(N):
        t0 = time.perf_counter()
        nv12_to_nv16(nv16)
        t.append((time.perf_counter() - t0) * 1e3)
    print("  " + stats(t))
    t_nv12 = float(np.mean(t))

    print("\n=== 2) 软件 cv2.imencode 1080p ===")
    for q in (49, 75):
        t = []
        for _ in range(N):
            t0 = time.perf_counter()
            ok, b = cv2.imencode(".jpg", img,
                                 [int(cv2.IMWRITE_JPEG_QUALITY), q])
            t.append((time.perf_counter() - t0) * 1e3)
        print("  Q%-3d %s   (%d B)" % (q, stats(t), len(b)))
        if q == 75:
            t_sw = float(np.mean(t))

    print("\n=== 3) 硬件 mppjpegenc 一帧往返 (写 pipe -> VPU 编码 -> 读回) ===")
    enc = HwEnc()
    for _ in range(5):
        j = enc.encode(nv12)
        if j is None:
            print("  ! 硬件编码无输出, 跳过")
            enc.close()
            return
    t = []
    for _ in range(N):
        t0 = time.perf_counter()
        j = enc.encode(nv12)
        t.append((time.perf_counter() - t0) * 1e3)
        if j is None:
            print("  ! 超时")
            break
    print("  " + stats(t) + "   (%d B)" % (len(j) if j else 0))
    t_hw = float(np.mean(t))

    print("\n=== 4) 硬件 5 帧「深灌」吞吐 (不等回帧, 一口气灌 5 帧再读 5 帧) ===")
    D = 5
    t = []
    for _ in range(N):
        t0 = time.perf_counter()
        for _ in range(D):
            mv = memoryview(nv12)
            while mv:
                n = enc.p.stdin.write(mv)
                if not n:
                    break
                mv = mv[n:]
        got = 0
        while got < D:
            try:
                if enc.q.get(timeout=2.0) is None:
                    break
                got += 1
            except queue.Empty:
                break
        if got == D:
            t.append((time.perf_counter() - t0) * 1e3 / D)
    if t:
        print("  " + stats(t) + "  <- 这是 VPU 真实每帧成本(不含管道往返空等)")
        t_hw_deep = float(np.mean(t))
    else:
        t_hw_deep = float("nan")
    enc.close()

    print("\n=== 汇总 (单帧串行耗时, 60fps 预算 = 16.67 ms) ===")
    print("  软件路径: _to_bgr + imencode    ≈ %.1f ms  -> 3 线程并行, "
          "吞吐 ≈ %.0f fps" % (t_sw, 3 * 1000.0 / t_sw))
    print("  硬件路径: nv12 + 一帧往返      ≈ %.1f ms  -> 单线程串行, "
          "吞吐 ≈ %.0f fps" % (t_nv12 + t_hw, 1000.0 / (t_nv12 + t_hw)))
    print("  其中 nv12 %.1f ms + 硬编往返 %.1f ms" % (t_nv12, t_hw))
    if t_hw_deep == t_hw_deep:
        print("  硬编纯吞吐 %.1f ms/帧 -> 说明往返里有 %.1f ms 是管道空等(可借流水填掉)"
              % (t_hw_deep, t_hw - t_hw_deep))


if __name__ == "__main__":
    main()
