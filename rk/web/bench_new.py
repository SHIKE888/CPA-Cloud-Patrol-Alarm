#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_new.py —— 新旧 yuv_to_bgr 对比: 耗时 + 数值一致性

用法:
  pkill -f 'mipi_web[s]tream'
  /opt/miniforge3/envs/mlk-ov/bin/python bench_new.py [/dev/video22]
"""
import os
import sys
import time

import numpy as np
import cv2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mipi_webstream as mw          # noqa: E402

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/video22"
W, H, TW, TH = 1920, 1080, 1280, 720
N = 15


def old_impl(buf, w, h, matrix="709", rng="limited", target=None):
    """改造前的 float32 实现(保留作对照)"""
    n = w * h
    y = buf[:n].reshape(h, w)
    c = buf[n:n + n].reshape(h, w // 2, 2)
    if target:
        tw, th = target
        y = cv2.resize(y, (tw, th), interpolation=cv2.INTER_AREA)
        c = cv2.resize(c, (tw // 2, th), interpolation=cv2.INTER_AREA)
        w, h = tw, th
    y = y.astype(np.float32)
    u = c[:, :, 0].astype(np.float32) - 128.0
    v = c[:, :, 1].astype(np.float32) - 128.0
    if rng == "limited":
        y -= 16.0
        y *= (255.0 / 219.0)
        u *= (255.0 / 224.0)
        v *= (255.0 / 224.0)
    kr, kgu, kgv, kb = mw.YUV_MATRIX[matrix]
    yr = y.reshape(h, w // 2, 2)
    u3, v3 = u[:, :, None], v[:, :, None]
    out = np.empty((h, w // 2, 2, 3), np.uint8)
    for i, ch in enumerate((yr + kb * u3,
                            yr + kgu * u3 + kgv * v3,
                            yr + kr * v3)):
        np.clip(ch, 0, 255, out=ch)
        np.rint(ch, out=ch)
        out[..., i] = ch
    return out.reshape(h, w, 3)


def main():
    cap = cv2.VideoCapture(DEV, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"NV16"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)
    if not cap.isOpened():
        print("打不开设备"); return 1
    ok, frame = cap.read()
    if not ok:
        print("读帧失败"); return 1
    buf = frame.reshape(-1)

    ref = old_impl(buf, W, H, target=(TW, TH))
    new = mw.yuv_to_bgr(buf, W, H, target=(TW, TH))

    def t_old():
        return old_impl(buf, W, H, target=(TW, TH))

    def t_new():
        return mw.yuv_to_bgr(buf, W, H, target=(TW, TH))

    t_old(); t_new()                       # warm
    t0 = time.time()
    for _ in range(N):
        t_old()
    ms_old = (time.time() - t0) / N * 1000
    t0 = time.time()
    for _ in range(N):
        t_new()
    ms_new = (time.time() - t0) / N * 1000

    d = new.astype(np.int16) - ref.astype(np.int16)
    ad = np.abs(d)
    print("=== 数值一致性 (int16 LUT 版 vs float32 版) ===")
    print("  平均绝对差 : %.4f" % ad.mean())
    print("  最大绝对差 : %d" % ad.max())
    print("  >1 LSB 的比例: %.3f%%" % (100.0 * (ad > 1).mean()))
    print()
    print("=== 耗时 ===")
    print("  float32 版      : %6.1f ms" % ms_old)
    print("  int16 LUT 版    : %6.1f ms   (快 %.2f 倍)" % (ms_new, ms_old / ms_new))

    # 端到端估算
    print()
    print("=== 端到端估算 (read 25.3ms + 转换 + imencode 8.1ms + 限帧) ===")
    for name, ms in (("float32", ms_old), ("int16 LUT", ms_new)):
        tot = 25.3 + ms + 8.1
        print("  %-10s 每帧 %6.1f ms  ->  约 %.1f fps" % (name, tot, 1000.0 / tot))

    cv2.imwrite("/tmp/conv_new.jpg", new)
    cap.release()
    return 0


if __name__ == "__main__":
    sys.exit(main())
