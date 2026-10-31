#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""measure_dual_shear.py —— 量双目拼接里"半边图像每行被平移了多少像素"

判断依据：
  1) 相邻两行做 1D 归一化相关，求平移量（同时报告"次优峰"离最优峰多远，
     避免被图像里的重复结构骗到）；
  2) 用"逐行反向平移后竖直梯度能量"做一次全局扫描：只有把一行的错位
     抵消掉，图像才会重新变成一幅连贯的画面，竖直梯度能量出现明显峰值。
     这一步不依赖相关峰，是独立验证。

用法(板上):
    /opt/miniforge3/envs/mlk-ov/bin/python measure_dual_shear.py /tmp/dual_snap.jpg
"""
from __future__ import print_function

import sys

import cv2
import numpy as np


def row_shift(a, b, maxs=20):
    """返回 (最优平移, 最优相关, 次优相关)。"""
    scores = {}
    for s in range(-maxs, maxs + 1):
        if s >= 0:
            x, y = a[s:], b[:b.size - s]
        else:
            x, y = a[:a.size + s], b[-s:]
        if x.size < 400:
            continue
        x = x - x.mean()
        y = y - y.mean()
        d = float(np.sum(x * y) / (np.sqrt(np.sum(x * x) * np.sum(y * y)) + 1e-9))
        scores[s] = d
    if not scores:
        return 0, -1.0, 1.0
    best_s = max(scores, key=scores.get)
    best = scores[best_s]
    second = -1.0
    for s, v in scores.items():
        if abs(s - best_s) > 3:
            second = max(second, v)
    return best_s, best, second


def deskew_scan(half, kmin=-12.0, kmax=12.0, step=0.25):
    """对候选斜率 k(px/row) 逐行反向平移，返回让竖直梯度最大的 k。"""
    g = half.astype(np.float32)[::3, ::3]
    hh, ww = g.shape
    ys = np.arange(hh, dtype=np.float32) * 3.0
    xs = np.arange(ww, dtype=np.float32)[None, :].repeat(hh, axis=0)
    mapy = np.arange(hh, dtype=np.float32)[:, None].repeat(ww, axis=1)
    best = (-1.0, 0.0)
    k = kmin
    while k <= kmax + 1e-6:
        mapx = np.mod(xs - k * ys[:, None], ww - 1).astype(np.float32)
        dw = cv2.remap(g, mapx, mapy, cv2.INTER_LINEAR,
                       borderMode=cv2.BORDER_WRAP)
        gy = float(np.abs(np.diff(dw, axis=0)).mean())
        if gy > best[0]:
            best = (gy, k)
        k += step
    return best


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/dual_snap.jpg"
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise SystemExit("读不到 %s" % path)
    h, w = img.shape
    hw = w // 2
    print("图像 %dx%d，右半边 x=%d..%d" % (w, h, hw, w - 1))

    for tag, half in (("左(cam1)", img[:, :hw]), ("右(cam0)", img[:, hw:])):
        g = half.astype(np.float32)
        shifts, ratios = [], []
        for i in range(20, h - 2, 7):
            a, b = g[i], g[i + 1]
            if a.std() < 3.0 or b.std() < 3.0:
                continue
            s, sc, second = row_shift(a, b)
            if sc < 0.2:                  # 相关性太差的行不算
                continue
            shifts.append(s)
            ratios.append(second / sc if sc > 1e-6 else 1.0)
        if not shifts:
            print("%s: 没有可用的行" % tag)
            continue
        s = np.array(shifts, dtype=np.float32)
        print("%s: 相邻行平移 中位 %.2f px/row  (样本 %d, 次优/最优相关比 %.2f)"
              % (tag, float(np.median(s)), s.size, float(np.median(ratios))))
        print("        外推到 1000 行 ≈ %.0f px（图宽 %d）"
              % (float(np.median(s)) * 1000, hw))
        gy, k = deskew_scan(half)
        print("        去斜扫描: 竖直梯度最佳斜率 k = %.2f px/row (能量 %.2f)"
              % (k, gy))


if __name__ == "__main__":
    sys.exit(main())
