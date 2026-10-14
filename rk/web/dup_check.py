#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dup_check.py —— 检测链路送来的是真 60fps 还是"重复帧凑数"

FPGA 侧 ui_dbuf 的读端由 ui_vtc 以 1080p60 自由跑；如果写端(传感器)只有 30fps,
读端就会把同一帧重复送两遍 -> RK 看到 60fps 但内容只有 30fps。
本脚本逐帧比较, 重复帧的相邻差会接近 0。

用法:
  pkill -f 'mipi_web[s]tream'
  /opt/miniforge3/envs/mlk-ov/bin/python dup_check.py [/dev/video22]
"""
import sys

import numpy as np
import cv2

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/video22"
W, H = 1920, 1080
N = 40


def main():
    cap = cv2.VideoCapture(DEV, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"NV16"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)
    if not cap.isOpened():
        print("打不开 %s" % DEV)
        return 1

    frames = []
    for _ in range(N):
        ok, f = cap.read()
        if ok and f is not None:
            frames.append(f.reshape(-1).astype(np.int16))
    cap.release()

    n = len(frames)
    print("抓到 %d 帧 (每帧 %d 字节)" % (n, frames[0].size if n else 0))
    if n < 4:
        print("帧太少"); return 1

    d1 = [float(np.abs(frames[i + 1] - frames[i]).mean()) for i in range(n - 1)]
    dup = sum(1 for v in d1 if v < 0.5)

    print("\n相邻帧平均绝对差:")
    print("  min=%.3f  中位=%.3f  max=%.3f" % (min(d1), float(np.median(d1)), max(d1)))
    print("  几乎完全相同(重复帧)的相邻对: %d / %d" % (dup, len(d1)))
    print("  前 12 个: %s" % np.round(d1[:12], 2))

    print()
    if dup > len(d1) * 0.3:
        print("=> 结论: **存在大量重复帧**。链路虽有 60fps, 但内容只有约 %d fps。"
              % round(60 * (len(d1) - dup) / len(d1)))
        print("   FPGA 侧 ui_dbuf 读端(VTC 60Hz)快于写端(传感器) —— 需要把")
        print("   IMX415 配置成真正的 1080p60 模式(ui_imx415_reg.v 的 VMAX/HMAX),")
        print("   或把 ui_vtc 也降到 30Hz。")
    else:
        print("=> 结论: 相邻帧都有明显差异, **是真实 60fps 内容**(或场景在动)。")
        print("   若想彻底排除'静态场景看不出差异'的干扰, 可以让画面里有个运动的物体再测。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
