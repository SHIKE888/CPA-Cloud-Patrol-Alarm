#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""analyze_preproc.py —— 判断抓到的帧是「原图 / Sobel / 阈值 / 形态学」哪一种

判据 (预处理流水线 P4/P5/P6 的输出特征差别很大):
  原图   : 有彩色 (R/G/B 不等), 所以"灰度像素占比"低
  Sobel  : 只对亮度做梯度 -> R==G==B (灰度), 灰阶多值, 均值偏低
  阈值   : 亮度二值化 -> 灰度, 且**只有 2 个值** (0 / 255)
  形态学 : 也是在二值图上做腐蚀/膨胀 -> 灰度, 只有 2 个值,
           白像素占比与阈值分割不同 (腐蚀变少, 膨胀变多)

用法:
    /opt/miniforge3/envs/mlk-ov/bin/python analyze_preproc.py <png>
说明: 板上 /usr/bin/python3 没有 numpy/cv2, 必须用 miniforge 那个解释器。
"""
import sys

if len(sys.argv) < 2:
    print("用法: analyze_preproc.py <png>")
    sys.exit(1)

try:
    import cv2
    import numpy as np
except ImportError as e:
    print("缺模块: %s  (请用 /opt/miniforge3/envs/mlk-ov/bin/python)" % e)
    sys.exit(2)

path = sys.argv[1]
img = cv2.imread(path, cv2.IMREAD_COLOR)
if img is None:
    print("    !! 读不了 %s" % path)
    sys.exit(1)

b = img[:, :, 0].astype(np.int16)
g = img[:, :, 1].astype(np.int16)
r = img[:, :, 2].astype(np.int16)

# 灰度像素: R/G/B 三者接近
is_gray = (np.abs(r - g) < 6) & (np.abs(g - b) < 6)
pct_gray = float(is_gray.mean()) * 100.0

vals, cnts = np.unique(r, return_counts=True)
n_uniq = int(len(vals))
mean_r = float(r.mean())
pct_white = float((r > 200).mean()) * 100.0

print("    %s" % path)
print("      尺寸          : %dx%d" % (img.shape[1], img.shape[0]))
print("      灰度像素占比  : %6.2f %%" % pct_gray)
print("      亮度唯一值数  : %4d" % n_uniq)
print("      亮度均值      : %6.1f" % mean_r)
print("      高亮(>200)占比: %6.2f %%" % pct_white)

if pct_gray > 95.0 and n_uniq <= 4:
    kind = "纯黑白 (阈值分割 / 形态学)"
elif pct_gray > 95.0:
    kind = "灰度多值 (Sobel 边缘)"
else:
    kind = "彩色 (原图直通)"
print("      => 判定: %s" % kind)
