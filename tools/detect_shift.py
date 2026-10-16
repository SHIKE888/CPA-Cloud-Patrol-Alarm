#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检测画面"左右错位"是【固定水平偏移】还是【逐行递增的剪切(shear)】。

用法: python detect_shift.py <y.raw> <w> <h>

原理: 取中间一行为参考, 让每一行在 dx∈[-60,60] 内平移去匹配参考行,
      记录最佳 dx。若 dx 基本不随行号变 -> 固定偏移(丢/多字);
      若 dx 随行号线性增长   -> 每行步进不匹配(stride/beat 数错), 会呈平行四边形。
"""
import sys

W, H = int(sys.argv[2]), int(sys.argv[3])
d = open(sys.argv[1], 'rb').read(W * H)
STEP, DX = 4, 60


def row(y):
    return d[y * W:(y + 1) * W]


ref = row(540)                    # 参考行
res = []
for y in range(20, H - 20, 40):
    r = row(y)
    best, bd = 0, None
    for dx in range(-DX, DX + 1):
        # 用中间 1/2 宽度做匹配, 避免边缘越界
        a = range(200, W - 200, STEP)
        s = 0
        n = 0
        for i in a:
            j = i + dx
            if 0 <= j < W:
                s += abs(ref[i] - r[j])
                n += 1
        if n == 0:
            continue
        v = s / n
        if bd is None or v < bd:
            bd, best = v, dx
    res.append((y, best, bd))

print("行号 -> 与参考行的最佳水平偏移 dx  (平均绝对差)")
for y, dx, bd in res:
    print("  行%4d : dx=%+4d   (%.1f)  %s" % (y, dx, bd, '#' * max(0, dx + 30) if abs(dx) > 1 else ''))

# 线性拟合 dx ~ a*y + b
n = len(res)
sy = sum(r[0] for r in res)
sx = sum(r[1] for r in res)
syy = sum(r[0] * r[0] for r in res)
sxy = sum(r[0] * r[1] for r in res)
den = n * syy - sy * sy
if den:
    a = (n * sxy - sy * sx) / den
    b = (sx - a * sy) / n
    print()
    print("线性拟合: dx = %.5f * row + %.2f" % (a, b))
    print("  每行递增 %.5f 像素 -> 1080 行累计偏移 %.1f 像素" % (a, a * H))
    print("  判定: %s" % ("逐行递增 = 剪切/stride 错位" if abs(a) > 0.01 else "基本固定偏移"))
else:
    print("拟合失败")

# 行内是否有垂直"接缝"(固定偏移时, 跳变位置会很明显)
print()
print("=== 参考行(540) 的相邻差, 找最大跳变位置 ===")
r = row(540)
jumps = sorted(((abs(r[i + 1] - r[i]), i) for i in range(0, W - 1, 1)), reverse=True)[:8]
for v, i in jumps:
    print("  x=%4d 跳变 %d" % (i, v))
