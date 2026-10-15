#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""diag_frame.py —— 诊断抓帧为什么是黑的

区分两种截然不同的成因:
  (a) 真实暗噪声  : 传感器在工作, 只是没光/曝光太短
                    -> 亮度值近似泊松分布, 空间上随机, 有微弱彩色性
  (b) 结构性错误  : 数据通路有 bug (错位/恒零/重复)
                    -> 出现规律的行列结构、整块恒定值、明显的边界

用法: python tools/diag_frame.py <png> [png2 ...]
"""
import sys

import numpy as np
from PIL import Image

for path in sys.argv[1:]:
    a = np.asarray(Image.open(path).convert('RGB')).astype(np.int32)
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    lum = (77 * r + 150 * g + 29 * b) >> 8

    print("=" * 66)
    print("%s   %dx%d" % (path, a.shape[1], a.shape[0]))
    print("=" * 66)

    print("\n[亮度统计]")
    print("  min/max       : %d / %d" % (lum.min(), lum.max()))
    print("  mean / std    : %.2f / %.2f" % (lum.mean(), lum.std()))
    print("  非零像素占比  : %.4f %%" % (100.0 * (lum > 0).mean()))

    print("\n[亮度直方图]")
    h, _ = np.histogram(lum, bins=16, range=(0, 256))
    for i, c in enumerate(h):
        if c:
            print("  %3d-%3d : %10d  %7.4f%%" % (i * 16, i * 16 + 15, c,
                                                 100.0 * c / lum.size))

    print("\n[行列结构 —— 有结构=帧错位, 无结构=真实暗]")
    rm = lum.mean(axis=1)
    cm = lum.mean(axis=0)
    print("  行均值 前4 : %s" % np.round(rm[:4], 2))
    print("         后4 : %s" % np.round(rm[-4:], 2))
    print("         极值: max %.2f @行%d / min %.2f @行%d / std %.3f"
          % (rm.max(), rm.argmax(), rm.min(), rm.argmin(), rm.std()))
    print("  列均值 前4 : %s" % np.round(cm[:4], 2))
    print("         后4 : %s" % np.round(cm[-4:], 2))
    print("         极值: max %.2f @列%d / min %.2f @列%d / std %.3f"
          % (cm.max(), cm.argmax(), cm.min(), cm.argmin(), cm.std()))

    print("\n[彩色性 —— 真实彩色画面应有 R!=G!=B]")
    print("  |R-G|>6 占比  : %.4f %%" % (100.0 * (np.abs(r - g) > 6).mean()))
    print("  |G-B|>6 占比  : %.4f %%" % (100.0 * (np.abs(g - b) > 6).mean()))

    print("\n[非零像素空间分布]")
    ys, xs = np.nonzero(lum > 10)
    if len(ys):
        print("  >10 的像素数  : %d" % len(ys))
        print("  行范围        : %d .. %d" % (ys.min(), ys.max()))
        print("  列范围        : %d .. %d" % (xs.min(), xs.max()))
    else:
        print("  纯黑 (没有 >10 的像素)")
    print()
