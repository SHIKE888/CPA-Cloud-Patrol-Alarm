#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""diag_ref.py —— 定位 jpeg_ref.py 输出异常的原因

症状: PIL 能解码(说明标记段合法), 但 PSNR 只有 6.3dB 且体积是 PIL 的 3.3 倍
      -> 典型的「系数排列错乱」: 高频能量没被压缩掉, 分散到全图。

策略: 把"亮度"和"色度"分开考察, 定位是 DCT/量化/排序 还是 颜色处理出错。
"""
import io
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from jpeg_ref import (make_test_yuv, yuv_to_rgb709, encode, psnr,
                      B_MAT, QB, RQ, fdct_blocks, ZIGZAG, seg_soi)  # noqa


def luma(rgb):
    r, g, b = rgb[..., 0].astype(np.float64), rgb[..., 1].astype(np.float64), \
        rgb[..., 2].astype(np.float64)
    return 0.299 * r + 0.587 * g + 0.114 * b


def main():
    quality = 75
    print("=" * 70)
    print(" jpeg_ref 诊断")
    print("=" * 70)

    # ---------------------------------------------------------------- 1
    print("\n[1] DCT 是否与解析公式一致? (取一个脉冲块, 直接和 float64 比)")
    # 脉冲: 只有 (0,0) 处为 1 -> DCT 应为 (1/4)c(u)c(v)cos(.)cos(.)
    imp = np.zeros((1, 8, 8), dtype=np.int64)
    imp[0, 0, 0] = 1
    F = fdct_blocks(imp)[0]
    Bf = np.array([[((1 / np.sqrt(2)) if k == 0 else 1.0)
                    * np.cos((2 * n + 1) * k * np.pi / 16)
                    for n in range(8)] for k in range(8)])
    # F[v][u] 应等于 (1/4) c(u)c(v) cos(0*u)cos(0*v) = 0.25*c(u)*c(v)
    expect = 0.25 * Bf[:, 0][:, None] * Bf[:, 0][None, :]   # [v][u]
    print("    F[0][0]=%d (期望 %.3f)  F[1][0]=%d (期望 %.3f)  F[0][1]=%d (期望 %.3f)"
          % (F[0, 0], expect[0, 0], F[1, 0], expect[1, 0], F[0, 1], expect[0, 1]))
    print("    F[7][7]=%d (期望 %.3f)" % (F[7, 7], expect[7, 7]))

    # ---------------------------------------------------------------- 2
    print("\n[2] 用一个「低频」图案, 看系数是否集中在左上角")
    ramp = np.arange(8, dtype=np.int64)[None, :].repeat(8, 0)   # 水平渐变
    Fr = fdct_blocks(ramp[None, :, :])[0]
    print("    水平渐变块的 F[v][u] (每项除以最大值的百分比):")
    mx = max(1, int(np.abs(Fr).max()))
    for v in range(8):
        print("      " + " ".join("%5.1f" % (100.0 * Fr[v, u] / mx) for u in range(8)))
    nz = int((np.abs(Fr) > 0).sum())
    print("    非零系数 %d 个 (水平渐变理论上只有 u=0 那一列非零)" % nz)

    # ---------------------------------------------------------------- 3
    print("\n[3] 编码并检查: 亮度 / 色度 分别比较")
    yuv = make_test_yuv(1920, 1080)
    data, st = encode(yuv, quality=quality, verbose=False)
    ref = yuv_to_rgb709(yuv)
    dec = np.asarray(Image.open(io.BytesIO(data)).convert('RGB'))

    ly, ld = luma(ref), luma(dec)
    print("    亮度 PSNR      = %.2f dB" % psnr(ld, ly))
    # 色度: 用 (B-luma), (R-luma) 表征
    for name, f in (("R-luma", lambda a: a[..., 0] - luma(a)),
                    ("B-luma", lambda a: a[..., 2] - luma(a))):
        print("    %-7s PSNR  = %.2f dB" % (name, psnr(f(dec), f(ref))))

    print("    参考图  R/G/B 均值 = %.1f / %.1f / %.1f" %
          tuple(ref.reshape(-1, 3).mean(0)))
    print("    解码图  R/G/B 均值 = %.1f / %.1f / %.1f" %
          tuple(dec.reshape(-1, 3).mean(0)))

    # ---------------------------------------------------------------- 4
    print("\n[4] 用 PIL 编同质量同采样, 看两者的系数统计差异")
    buf = io.BytesIO()
    Image.fromarray(ref).save(buf, format='JPEG', quality=quality,
                              subsampling='4:2:2')
    pil = buf.getvalue()
    print("    本实现 %d 字节   PIL %d 字节   比值 %.2f"
          % (len(data), len(pil), len(data) / float(len(pil))))

    # 直接看熵编码字节数 vs 头部字节数
    print("    本实现: 熵编码 %d 字节 (%.1f%%), 头部 %d 字节"
          % (st['bytes'] - len(st.get('head', b'')), 
             100.0 * 386309 / st['bytes'], len(st.get('head', b''))))

    # ---------------------------------------------------------------- 5
    print("\n[5] 逐块核对: 手工算一块的量化系数, 和 dump 对比")
    ref_block = ref[0:8, 0:8].astype(np.float64)
    # 用 ref RGB 反推不现实; 改用 Y 平面直接检查
    y_plane = yuv[0][0:8, 0:8].astype(np.int64)
    from jpeg_ref import expand_range
    ye = expand_range((yuv[0], yuv[1], yuv[2]))[0][0:8, 0:8].astype(np.int64)
    blk = (ye - 128)[None, :, :]
    Fb = fdct_blocks(blk)[0]
    print("    左上角 8x8 Y 块 (扩展色域后) 的 DCT:")
    print("      DC=%d  AC(0,1)=%d AC(1,0)=%d AC(1,1)=%d"
          % (Fb[0, 0], Fb[0, 1], Fb[1, 0], Fb[1, 1]))
    print("      zigzag 前 10 个: %s"
          % [int(Fb[ZIGZAG[z] // 8, ZIGZAG[z] % 8]) for z in range(10)])

    # ---------------------------------------------------------------- 6
    print("\n[6] 保存解码图供人工查看")
    Image.fromarray(dec).save(os.path.join(HERE, 'diag_mine.png'))
    print("    -> %s" % os.path.join(HERE, 'diag_mine.png'))
    print("\n" + "=" * 70)
    return 0


if __name__ == '__main__':
    sys.exit(main())
