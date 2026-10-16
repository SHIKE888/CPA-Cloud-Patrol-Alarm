#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分析 4K Y 平面的缺陷类型: 逐行平移 / 脉冲噪声 / 垂直错位。

用法: python analyze_y.py <y.raw> <w> <h>
"""
import sys

W, H = int(sys.argv[2]), int(sys.argv[3])
d = open(sys.argv[1], 'rb').read(W * H)


def row(y):
    return d[y * W:(y + 1) * W]


print("=== 1) 逐行水平平移 (与下一行最匹配的 dx) ===")
for yy in (100, 300, 540, 800, 1080, 1400, 1800, 2000):
    a = row(yy)
    b = row(yy + 1)
    best, bd = 0, None
    for dx in range(-16, 17):
        if dx >= 0:
            s = sum(abs(a[i] - b[i + dx]) for i in range(0, 2000, 7))
        else:
            s = sum(abs(a[i - dx] - b[i]) for i in range(0, 2000, 7))
        if bd is None or s < bd:
            bd, best = s, dx
    print("  行%4d vs 行%4d : 最佳 dx=%+3d  (平均差 %.1f)" % (yy, yy + 1, best, bd / (2000 / 7)))

print()
print("=== 2) 脉冲噪声率 (与左右邻居均值差 > 64 的像素占比) ===")
imp = tot = 0
for yy in range(100, 2100, 53):
    r = row(yy)
    for i in range(1, W - 1, 3):
        m = (r[i - 1] + r[i + 1]) / 2
        tot += 1
        if abs(r[i] - m) > 64:
            imp += 1
print("  脉冲率 = %.2f%%  (%d/%d)" % (100.0 * imp / tot, imp, tot))

print()
print("=== 3) 垂直错位 (与下一帧同样位置比 —— 需同一场景) ===")
print("  (跳过, 需两帧)")

print()
print("=== 4) 行内是否有周期性重复 (自相关, 看是否存在镜像/复制) ===")
r = row(1000)
for lag in (1, 2, 4, 8, 960, 1919, 1920, 1921, 2880):
    if lag >= W:
        continue
    a = r[:W - lag:4]
    b = r[lag::4]
    diff = sum(abs(x - y) for x, y in zip(a, b)) / len(a)
    print("  lag=%5d : 平均差 %.1f" % (lag, diff))

print()
print("=== 5) 亮度分布 ===")
h = [0] * 16
for i in range(0, W * H, 37):
    h[d[i] >> 4] += 1
n = sum(h)
print("  " + "  ".join("%3d-%3d:%.1f%%" % (i * 16, i * 16 + 15, 100.0 * c / n)
                       for i, c in enumerate(h) if c))
