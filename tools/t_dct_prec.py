#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""t_dct_prec.py —— 决定 RTL 的 DCT 定点精度方案 (写 RTL 前必须定下来)

背景: 当前 jpeg_ref 的定点 DCT 与 PIL(libjpeg) 相比 PSNR 差约 1.4dB
      (31.55 vs 32.95)。需要判断这个差距是否来自 DCT 精度 ——
      如果是, RTL 就要用更宽的中间位宽, 否则白写一遍。

对比 4 个方案:
  A  当前: QB=15, 两趟后各 >>15 舍入 (中间累加 ≤32 位)
  B  float64 精确 DCT (精度上限基准)
  C  QB=15, 第 1 趟只 >>11 (多留 4 位小数), 第 2 趟 >>19 (累加器需 34+ 位)
  D  QB=16, 同 A 结构 (累加器需 33 位)

输出: 每个方案的 |F_int - F_true| 统计 + 最终 PSNR + 体积
"""
import io
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jpeg_ref as JR          # noqa
from jpeg_ref import make_test_yuv, yuv_to_rgb709, psnr, B_MAT, QB, RQ  # noqa

BF = np.array([[((1 / np.sqrt(2)) if k == 0 else 1.0)
                * np.cos((2 * n + 1) * k * np.pi / 16) for n in range(8)]
               for k in range(8)])


# ---------------------------------------------------------------- 方案 B
def fdct_float(blk):
    b = blk.astype(np.float64)
    G = np.einsum('vy,nyx->nvx', BF, b)
    H = np.einsum('ux,nvx->nvu', BF, G)
    return np.round(H / 4.0).astype(np.int64)


# ---------------------------------------------------------------- 方案 C
def fdct_c(blk):
    """第 1 趟少右移 4 位 -> 中间结果多保留 4 位小数"""
    a1 = np.einsum('vy,nyx->nvx', B_MAT, blk)
    G = (a1 + (1 << 10)) >> 11                 # 保留 2^4 的缩放
    a2 = np.einsum('ux,nvx->nvu', B_MAT, G)
    H = (a2 + (1 << 18)) >> 19                 # 2^15 * 2^4 = 2^19
    return (H + 2) >> 2


# ---------------------------------------------------------------- 方案 D
B16 = np.round(B_MAT.astype(np.float64) * 2.0).astype(np.int64)   # QB=16


def fdct_d(blk):
    a1 = np.einsum('vy,nyx->nvx', B16, blk)
    G = (a1 + (1 << 15)) >> 16
    a2 = np.einsum('ux,nvx->nvu', B16, G)
    H = (a2 + (1 << 15)) >> 16
    return (H + 2) >> 2


VARIANTS = [
    ("A  当前 QB=15, 每趟 >>15", JR.fdct_blocks),
    ("B  float64 精确", fdct_float),
    ("C  QB=15, 第1趟>>11 (留4位小数)", fdct_c),
    ("D  QB=16", fdct_d),
]


def main():
    print("=" * 74)
    print(" DCT 定点精度方案对比")
    print("=" * 74)

    # ---- 1. 精度统计 (随机块, 与 float64 真值比) ----
    rng = np.random.default_rng(7)
    blk = rng.integers(-128, 128, (256, 8, 8)).astype(np.int64)
    true = fdct_float(blk)
    print("\n[1] |F_int - F_true|  (随机块 x256, 4:2:2 实际取值范围)")
    print("    %-34s %8s %8s %10s" % ("方案", "最大", "平均", "累加位宽"))
    wid = {"A  当前 QB=15, 每趟 >>15": 32, "B  float64 精确": 0,
           "C  QB=15, 第1趟>>11 (留4位小数)": 37, "D  QB=16": 33}
    stats = {}
    for name, fn in VARIANTS:
        F = fn(blk)
        e = np.abs(F.astype(np.float64) - true.astype(np.float64))
        stats[name] = (e.max(), e.mean())
        print("    %-34s %8.3f %8.3f %10d" % (name, e.max(), e.mean(),
                                              wid.get(name, 0)))

    # 用真实图像的块再测一次 (含高频细竖线, 更接近实际最难情况)
    yuv = make_test_yuv(1920, 1080)
    y0 = yuv[0][:64, :512].astype(np.int64) - 128
    yb = JR.to_blocks(y0.astype(np.int64) + 128)   # 注意 to_blocks 内部已减 128? 不, 这里手工
    yb = JR.to_blocks(yuv[0][:64, :512])
    yb = yb - 128
    tr2 = fdct_float(yb)
    print("\n    真实图像块 x512 (含 1/7 像素细竖线, 高频最极端情形):")
    for name, fn in VARIANTS:
        F = fn(yb)
        e = np.abs(F.astype(np.float64) - tr2.astype(np.float64))
        print("    %-34s %8.3f %8.3f" % (name, e.max(), e.mean()))

    # ---- 2. 端到端 PSNR / 体积 ----
    print("\n[2] 端到端 (quality=75, 4:2:2, 1920x1080)")
    ref = yuv_to_rgb709(yuv).astype(np.int32)
    buf = io.BytesIO()
    Image.fromarray(ref.astype(np.uint8)).save(buf, format='JPEG', quality=75,
                                               subsampling='4:2:2')
    pild = buf.getvalue()
    pildec = np.asarray(Image.open(io.BytesIO(pild)).convert('RGB')).astype(np.int32)
    print("    %-34s %8.2f dB  %8d B" % ("PIL(libjpeg) 参照",
                                         psnr(pildec, ref), len(pild)))

    orig = JR.fdct_blocks
    for name, fn in VARIANTS:
        JR.fdct_blocks = fn
        data, st = JR.encode(yuv, quality=75, verbose=False)
        dec = np.asarray(Image.open(io.BytesIO(data)).convert('RGB')).astype(np.int32)
        print("    %-34s %8.2f dB  %8d B" % (name, psnr(dec, ref), len(data)))
    JR.fdct_blocks = orig

    print("\n" + "=" * 74)
    print(" 结论: 选精度够用且位宽最小的方案写 RTL")
    print("=" * 74)


if __name__ == '__main__':
    sys.exit(main())
