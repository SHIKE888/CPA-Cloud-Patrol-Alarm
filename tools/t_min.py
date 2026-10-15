#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""t_min.py —— 用最小图(单 MCU / 常数)钉死编码器问题

小图可控, 可以直接把解码结果打印出来逐像素看。
"""
import io
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from jpeg_ref import encode, quality_scale_table, Q_LUM, Q_CHR  # noqa


def decode(data):
    return np.asarray(Image.open(io.BytesIO(data)).convert('RGB'))


def luma(rgb):
    return (0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2])


def case(name, Y, Cb, Cr, expect=None):
    data, st = encode((Y, Cb, Cr), quality=75, expand=False, verbose=False)
    dec = decode(data)
    got = luma(dec)
    print("\n--- %s ---" % name)
    print("  输入 Y 唯一值: %s" % np.unique(Y)[:8])
    print("  解码 luma 均值 %.2f  范围 %.1f..%.1f"
          % (got.mean(), got.min(), got.max()))
    if expect is not None:
        err = got - expect
        print("  期望均值 %.2f -> 误差均值 %.3f  最大绝对误差 %.3f"
              % (expect.mean(), err.mean(), np.abs(err).max()))
        ok = np.abs(err).max() < 3.0
        print("  %s" % ("OK 一致" if ok else "✗ 不一致"))
        if not ok:
            print("  解码 luma (前 4x8):")
            for r in range(min(4, got.shape[0])):
                print("    " + " ".join("%6.1f" % v for v in got[r, :8]))
            print("  期望 (前 4x8):")
            for r in range(min(4, expect.shape[0])):
                print("    " + " ".join("%6.1f" % v for v in expect[r, :8]))
        return ok
    return True


print("=" * 70)
print(" 最小图测试 (expand=False, 直接喂电平移位后的 YUV)")
print("=" * 70)

q, _ = quality_scale_table(Q_LUM, 75)
print("\n质量75 亮度量化表(自然序前8): %s ..." % q[:8].tolist())
print("  -> DC 量化步长 Q[0] = %d" % q[0])

allok = True

# ---- 1. 常数图: 全 128 (移位后 = 0), 所有系数应为 0 ----
Y = np.full((8, 16), 128, np.uint8)
C = np.full((8, 8), 128, np.uint8)
allok &= case("常数 128 (理论全部系数=0)", Y, C, C, expect=np.full((8, 16), 128.0))

# ---- 2. 常数 0 ----
Y = np.zeros((8, 16), np.uint8)
C = np.full((8, 8), 128, np.uint8)
allok &= case("常数 0", Y, C, C, expect=np.zeros((8, 16)))

# ---- 3. 常数 255 ----
Y = np.full((8, 16), 255, np.uint8)
allok &= case("常数 255", Y, C, C, expect=np.full((8, 16), 255.0))

# ---- 4. 水平渐变 ----
Y = np.zeros((8, 16), np.uint8)
Y[:, :] = (np.arange(16) * 8 + 64)[None, :]
C = np.full((8, 8), 128, np.uint8)
allok &= case("水平渐变 64..184", Y, C, C, expect=Y.astype(float))

# ---- 5. 垂直渐变 ----
Y = np.zeros((8, 16), np.uint8)
Y[:, :] = (np.arange(8) * 16 + 64)[:, None]
allok &= case("垂直渐变 64..176", Y, C, C, expect=Y.astype(float))

# ---- 6. 棋盘 (高频) ----
Y = np.zeros((8, 16), np.uint8)
Y[:, 0::2] = 200
Y[:, 1::2] = 60
allok &= case("棋盘(高频, 会有量化损失)", Y, C, C, expect=Y.astype(float))

# ---- 7. 跨 MCU: 32x16, 左右两半不同 ----
Y = np.zeros((16, 32), np.uint8)
Y[:8, :] = 80
Y[8:, :] = 180
C = np.full((16, 16), 128, np.uint8)
allok &= case("上下两段 80/180 (检查 DC 预测)", Y, C, C, expect=Y.astype(float))

print("\n" + "=" * 70)
print(" 结论: %s" % ("全部通过" if allok else "**有失败项**"))
print("=" * 70)
sys.exit(0 if allok else 1)
