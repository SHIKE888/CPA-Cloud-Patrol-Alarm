#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""t_big.py —— 大图问题定位: 抽掉「颜色/解码器色度上采样」这个变量

小图全部通过 -> DCT/量化/熵编码/标记段都是对的。
所以只剩两种可能:
  (a) 编码器在大图上出错 (DC 漂移 / 块顺序)
  (b) 比较方法本身有问题 (PIL 用 BT.601 + 插值上采样色度, 我拿 BT.709 参考去比)

做法: 让色度恒定 (Cb=Cr=128), 这样解码 RGB 三通道相等, 直接把解码 luma
      和输入 Y 逐像素比 —— 完全绕开颜色矩阵和色度上采样。
"""
import io
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from jpeg_ref import encode, psnr, expand_range, make_test_yuv  # noqa


def decode(data):
    return np.asarray(Image.open(io.BytesIO(data)).convert('RGB')).astype(np.int32)


def luma(rgb):
    return (0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2])


def report(tag, ydec, yref):
    err = ydec - yref
    print("  %-34s PSNR %6.2f dB   误差 均值%+7.3f 最大%6.2f  RMSE%6.2f"
          % (tag, psnr(ydec, yref), err.mean(), np.abs(err).max(),
             np.sqrt((err ** 2).mean())))
    return err


print("=" * 74)
print(" 大图定位 (色度置常数, 只看亮度)")
print("=" * 74)

W, H = 1920, 1080
yuv0 = make_test_yuv(W, H)
C128 = np.full((H, W // 2), 128, np.uint8)

# ---------------------------------------------------------------- A
print("\n[A] expand=False, 色度=128  ->  解码 luma 应等于输入 Y")
Y = yuv0[0]
data, st = encode((Y, C128, C128), quality=75, expand=False, verbose=False)
e = report("A: 1080p 全图", luma(decode(data)), Y.astype(np.int32))
print("      输出 %d 字节 (%.2f bpp)" % (len(data), len(data) * 8.0 / (W * H)))

# 误差有没有空间周期性? (块边界错位会表现为周期性)
print("      按列 mod 16 的平均误差:")
rowerr = np.abs(e).mean(0)
print("        " + " ".join("%5.2f" % rowerr[c::16].mean() for c in range(16)))
print("      按行 mod 8 的平均误差:")
colerr = np.abs(e).mean(1)
print("        " + " ".join("%5.2f" % colerr[r::8].mean() for r in range(8)))

# ---------------------------------------------------------------- B
print("\n[B] 只取左上 128x64 小块, 排除大图累积因素")
Ys = Y[:64, :128]
Cs = C128[:64, :64]
data, _ = encode((Ys, Cs, Cs), quality=75, expand=False, verbose=False)
report("B: 128x64", luma(decode(data)), Ys.astype(np.int32))

# ---------------------------------------------------------------- C
print("\n[C] 逐 MCU 行单独编码, 看是否某一行起开始崩")
for my in (0, 1, 2, 50, 134):
    Ys = Y[my * 8:my * 8 + 8, :192]
    Cs = C128[my * 8:my * 8 + 8, :96]
    data, _ = encode((Ys, Cs, Cs), quality=75, expand=False, verbose=False)
    report("C: 仅第 %3d 个 MCU 行 (8x192)" % my, luma(decode(data)),
           Ys.astype(np.int32))

# ---------------------------------------------------------------- D
print("\n[D] expand 色域扩展是否正确")
Ye, Ce, Cre = expand_range(yuv0)
print("      输入 Y  min/max = %d/%d" % (yuv0[0].min(), yuv0[0].max()))
print("      扩展 Y  min/max = %d/%d  (理论 16->0, 235->255)"
      % (Ye.min(), Ye.max()))
print("      扩展 Cb min/max = %d/%d  (理论 16->0? 实际是绕 128 扩展)"
      % (Ce.min(), Ce.max()))
chk = ((np.arange(16, 236) - 16) * 255 // 219)
print("      Y=16..235 映射后范围 [%d, %d]" % (chk.min(), chk.max()))

# ---------------------------------------------------------------- E
print("\n[E] 用 BT.601 参考再比一次大图 (验证是不是矩阵不匹配)")
from jpeg_ref import encode as enc
data, _ = enc(yuv0, quality=75, expand=True, verbose=False)
dec = decode(data)


def yuv_to_rgb601(yuv):
    Yp, Cbp, Crp = yuv
    Yp = Yp.astype(np.float64)
    Cbp = np.repeat(Cbp.astype(np.float64), 2, axis=1) - 128.0
    Crp = np.repeat(Crp.astype(np.float64), 2, axis=1) - 128.0
    yl = (Yp - 16.0) / 219.0 * 255.0
    R = np.clip(yl + 1.402 * Crp, 0, 255)
    G = np.clip(yl - 0.344136 * Cbp - 0.714136 * Crp, 0, 255)
    B = np.clip(yl + 1.772 * Cbp, 0, 255)
    return np.dstack([R, G, B]).astype(np.uint8)


def yuv_to_rgb709f(yuv):
    from jpeg_ref import yuv_to_rgb709
    return yuv_to_rgb709(yuv)


r709 = yuv_to_rgb709f(yuv0).astype(np.int32)
r601 = yuv_to_rgb601(yuv0).astype(np.int32)
print("  %-34s PSNR %6.2f dB" % ("解码 vs BT.709 参考", psnr(dec, r709)))
print("  %-34s PSNR %6.2f dB" % ("解码 vs BT.601 参考", psnr(dec, r601)))
print("  %-34s PSNR %6.2f dB" % ("BT.709 参考 vs BT.601 参考",
                                 psnr(r709, r601)))

# ---------------------------------------------------------------- F
print("\n[F] 只比亮度通道 (排除色度上采样)")
print("  %-34s PSNR %6.2f dB" % ("luma(解码) vs luma(BT.709参考)",
                                 psnr(luma(dec), luma(r709))))
print("  %-34s PSNR %6.2f dB" % ("luma(解码) vs luma(BT.601参考)",
                                 psnr(luma(dec), luma(r601))))

print("\n" + "=" * 74)
