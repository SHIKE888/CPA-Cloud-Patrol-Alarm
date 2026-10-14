#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_stages.py —— 逐阶段计时, 找出 opencv 后端真正的瓶颈

用法:
  pkill -f 'mipi_web[s]tream'
  /opt/miniforge3/envs/mlk-ov/bin/python bench_stages.py [/dev/video22]
"""
import os
import sys
import time

import numpy as np
import cv2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mipi_webstream import yuv_to_bgr          # noqa: E402

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/video22"
W, H, TW, TH = 1920, 1080, 1280, 720
N = 25


def bench(name, fn, n=N):
    fn()
    t0 = time.time()
    for _ in range(n):
        r = fn()
    ms = (time.time() - t0) / n * 1000.0
    print("  %-42s %7.1f ms   (%.1f fps)" % (name, ms, 1000.0 / ms))
    return r


def main():
    print("cv2 %s   threads=%d" % (cv2.__version__, cv2.getNumThreads()))
    print("解析度: 采集 %dx%d -> 推流 %dx%d" % (W, H, TW, TH))
    print()

    cap = cv2.VideoCapture(DEV, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"NV16"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)
    if not cap.isOpened():
        print("打不开 %s (可能被 mipi_webstream 占用)" % DEV)
        return 1

    box = {}

    def do_read():
        ok, f = cap.read()
        box["frame"] = f
        return f
    bench("cap.read() 原始 NV16 1080p", do_read)

    frame = box["frame"]
    n = W * H
    if frame is None or frame.size != n * 2:
        print("读到的不是原始 NV16 (size=%s)" % (None if frame is None else frame.size))
        return 1

    def do_conv():
        return yuv_to_bgr(frame.reshape(-1), W, H, fmt="NV16",
                          matrix="709", rng="limited", target=(TW, TH))
    bgr = bench("yuv_to_bgr()  当前实现(709/limited 缩到720p)", do_conv)

    def do_enc():
        ok, b = cv2.imencode(".jpg", bgr,
                             [int(cv2.IMWRITE_JPEG_QUALITY), 80])
        return b
    bench("cv2.imencode() jpeg q80 720p", do_enc)

    print("\n  --- yuv_to_bgr 内部拆解 ---")
    buf = frame.reshape(-1)

    def st1():
        y = buf[:n].reshape(H, W)
        c = buf[n:2 * n].reshape(H, W // 2, 2)
        return (cv2.resize(y, (TW, TH), interpolation=cv2.INTER_AREA),
                cv2.resize(c, (TW // 2, TH), interpolation=cv2.INTER_AREA))
    y2, c2 = bench("  1) YUV 域 resize (uint8)", st1)

    def st2():
        yy = y2.astype(np.float32)
        u = c2[:, :, 0].astype(np.float32) - 128.0
        v = c2[:, :, 1].astype(np.float32) - 128.0
        yy -= 16.0
        yy *= (255.0 / 219.0)
        u *= (255.0 / 224.0)
        v *= (255.0 / 224.0)
        return yy, u, v
    bench("  2) astype float32 + 量程缩放", st2)

    def st3():
        yy, u, v = st2()
        u3, v3 = u[:, :, None], v[:, :, None]
        yr = yy.reshape(TH, TW // 2, 2)
        out = np.empty((TH, TW // 2, 2, 3), np.uint8)
        for i, ch in enumerate((yr + 1.8556 * u3,
                                yr - 0.1873 * u3 - 0.4681 * v3,
                                yr + 1.5748 * v3)):
            np.clip(ch, 0, 255, out=ch)
            np.rint(ch, out=ch)
            out[..., i] = ch
        return out
    bench("  3) 矩阵运算 + 裁剪 + 落 uint8", st3)

    def st_lut():
        # 备选: 用 cv2.LUT 在 uint8 域完成量程展开, cv2.cvtColor 做矩阵(SIMD)
        lut_y = np.clip((np.arange(256) - 16) * (255.0 / 219.0), 0, 255)
        lut_y = lut_y.astype(np.uint8)
        lut_c = np.clip(128.0 + (np.arange(256) - 128.0) * (255.0 / 224.0),
                        0, 255).astype(np.uint8)
        yl = cv2.LUT(y2, lut_y)
        cb = cv2.LUT(c2[:, :, 0], lut_c)
        cr = cv2.LUT(c2[:, :, 1], lut_c)
        yuyv = np.empty((TH, TW, 2), np.uint8)
        v4 = yuyv.reshape(TH, TW // 2, 4)
        v4[:, :, 0] = yl[:, 0::2]
        v4[:, :, 1] = cb
        v4[:, :, 2] = yl[:, 1::2]
        v4[:, :, 3] = cr
        return cv2.cvtColor(yuyv, cv2.COLOR_YUV2BGR_YUYV)
    alt = bench("  A) LUT + YUYV 交错 + cvtColor(601)", st_lut)

    d = (alt.astype(np.int16) - bgr.astype(np.int16))
    print("\n  A 方案 vs 当前方案: 均值差 %s   RMS %.2f"
          % (np.round(d.reshape(-1, 3).mean(0), 2),
             np.sqrt((d.astype(np.float32) ** 2).mean())))

    cap.release()
    print()
    print("结论: 看哪一步占用最大, 优先优化它。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
