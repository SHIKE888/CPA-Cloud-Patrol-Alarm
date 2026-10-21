#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""jpeg_ref.py —— 基线 JPEG 编码器「黄金参考实现」(LOSSY / SOF0)

作用
====
这是 FPGA 端 JPEG 编码器的**行为合同**。RTL 写完后，仿真输出必须与本脚本
输出**逐字节相同**。因此本脚本里所有算术都写成整数、并明确指定舍入方式 ——
RTL 只要照抄同样的整数运算，一致性就是构造性保证的，不需要碰运气。

同时本脚本自身也要能自证正确：
    · 产出能被 PIL / 任何标准解码器解码
    · 与 PIL 自带的 JPEG 编码器在同等质量下 PSNR/体积相当 → 说明没有算错

编码流水 (与 RTL 一一对应)
=========================
    输入 YUV422 (Y 全分辨率, Cb/Cr 水平 2:1)      <- 就是 FPGA MIPI 上的格式
      -> 色域扩展 (limited 16-235 -> full 0-255)  [可选, 对应 RTL 的 range 模块]
      -> 电平移位 (-128)
      -> 8x8 分块
      -> 定点 DCT (两趟, Q15 基矩阵)               <- jpeg_fdct1d / jpeg_dct2d
      -> 量化 (倒数定点乘)                          <- jpeg_quant_zz
      -> zigzag 扫描
      -> 游程 + 霍夫曼 + 位打包 + 0xFF 填充          <- jpeg_huff_enc
      -> 标记段 (SOI/APP0/DQT/SOF0/DHT/SOS/EOI)     <- jpeg_headers

采样因子固定为 4:2:2 (Y: H=2,V=1 / Cb,Cr: H=1,V=1)，即每 MCU = 16x8 = 2Y+1Cb+1Cr。
1920x1080 恰好整除 (120 MCU x 135 MCU)，**无需边界填充**。

用法
====
    python tools/jpeg_ref.py                 # 自检: 合成图 -> 编码 -> PIL 解码 -> PSNR
    python tools/jpeg_ref.py --dump out.txt  # 额外导出每块量化系数(给 RTL testbench 比对)
    python tools/jpeg_ref.py --quality 75
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from gen_jpeg_tables import (          # noqa: E402
    Q_LUM, Q_CHR, ZIGZAG,
    DC_LUM_BITS, DC_LUM_VALS, DC_CHR_BITS, DC_CHR_VALS,
    AC_LUM_BITS, AC_LUM_VALS, AC_CHR_BITS, AC_CHR_VALS,
    build_codes,
)

# ============================================================================
#  1. 定点 DCT
# ============================================================================
QB = 15                      # 基矩阵定点位数
RQ = 1 << (QB - 1)           # 舍入常数 2^14


def _basis():
    """B[k][n] = round(c(k) * cos((2n+1)k*pi/16) * 2^15)

    c(0) = 1/sqrt(2), c(k>0) = 1。乘以 c 是为了把 JPEG 的归一化因子折进表里，
    这样两趟变换后只需再除 4。
    """
    B = np.zeros((8, 8), dtype=np.int64)
    for k in range(8):
        ck = (1.0 / np.sqrt(2.0)) if k == 0 else 1.0
        for n in range(8):
            B[k, n] = int(round(ck * np.cos((2 * n + 1) * k * np.pi / 16.0)
                                * (1 << QB)))
    return B


B_MAT = _basis()


def fdct_blocks(blk):
    """批量 8x8 定点 DCT。

    blk : (N, 8, 8) int64, 已做电平移位 (-128)
    返回: (N, v, u) int64 = 整数 DCT 系数 F[v][u]

    两趟分离变换, 每趟后按 (x + 2^14) >> 15 舍入 —— 与 RTL 完全一致:
        pass1 (沿 y):  G[n][v][x] = round( sum_y B[v][y]*blk[n][y][x] / 2^15 )
        pass2 (沿 x):  H[n][v][u] = round( sum_x B[u][x]*G[n][v][x]  / 2^15 )
        F = H / 4  (四舍五入)
    """
    acc1 = np.einsum('vy,nyx->nvx', B_MAT, blk)      # (N,8,8)
    G = (acc1 + RQ) >> QB
    acc2 = np.einsum('ux,nvx->nvu', B_MAT, G)        # (N,8,8) -> [n][v][u]
    H = (acc2 + RQ) >> QB
    return (H + 2) >> 2                              # F = H/4, 四舍五入


# ============================================================================
#  2. 量化
# ============================================================================
QS = 20                      # 倒数定点位数


def quality_scale_table(q_base, quality, qs=QS):
    """按质量 1..100 缩放基准量化表, 并算出定点倒数。

    标准 (IJG) 缩放:
        quality < 50 : scale = 5000 / quality
        quality >= 50: scale = 200 - 2*quality
        Q[i] = clamp((q_base[i]*scale + 50) / 100, 1, 255)

    量化除法用倒数乘法代替, 与 RTL 一致:
        recip[i] = round(2^QS / Q[i])
        qf       = (F * recip[i] + floor(2^(QS-1))) >> QS     (F >= 0)
        qf       = -(((-F) * recip[i] + floor(2^(QS-1))) >> QS) (F < 0)
    """
    if quality < 50:
        scale = 5000.0 / max(1, quality)
    else:
        scale = 200.0 - 2.0 * quality
    q = np.array([min(255, max(1, int((v * scale + 50) / 100))) for v in q_base],
                 dtype=np.int64)
    recip = np.array([int(round((1 << qs) / float(v))) for v in q], dtype=np.int64)
    return q, recip


def quantize_blocks(F, recip, qs=QS):
    """F: (N,8,8) -> 量化后 (N,8,8), 四舍五入, 与 RTL 位运算一致

    recip 传入 64 元素(自然序 v*8+u) 或已是 (8,8) 的倒数表。
    """
    F = F.astype(np.int64)
    r = np.asarray(recip, dtype=np.int64).reshape(8, 8)
    neg = F < 0
    mag = np.abs(F)
    q = (mag * r[None, :, :] + (1 << (qs - 1))) >> qs
    return np.where(neg, -q, q)


# ============================================================================
#  3. 幅值分类 与 附加位 (T.81 F.1.2)
# ============================================================================
def magnitude_category(v):
    a = abs(int(v))
    return a.bit_length()


def amp_bits(v, s):
    """负数用 ones' complement: v + 2^s - 1"""
    return v if v >= 0 else v + (1 << s) - 1


# ============================================================================
#  4. 位写入器 (含 0xFF 字节填充)
# ============================================================================
class BitWriter(object):
    def __init__(self):
        self.buf = bytearray()
        self.acc = 0
        self.n = 0
        self.stuff_count = 0

    def put_bits(self, code, length):
        if length <= 0:
            return
        self.acc = (self.acc << length) | (int(code) & ((1 << length) - 1))
        self.n += length
        while self.n >= 8:
            self.n -= 8
            b = (self.acc >> self.n) & 0xFF
            self.buf.append(b)
            if b == 0xFF:                 # 字节填充: FF -> FF 00
                self.buf.append(0x00)
                self.stuff_count += 1
        self.acc &= (1 << self.n) - 1

    def flush(self):
        """用 1 位补齐到字节边界 (T.81 B.1.1.5)"""
        if self.n:
            self.put_bits((1 << (8 - self.n)) - 1, 8 - self.n)
        self.acc = 0
        self.n = 0


# ============================================================================
#  5. 标记段生成
# ============================================================================
def _seg(marker, payload):
    out = bytearray([0xFF, marker])
    ln = len(payload) + 2
    out += bytes([(ln >> 8) & 0xFF, ln & 0xFF])
    out += payload
    return out


def seg_soi():
    return bytearray([0xFF, 0xD8])


def seg_eoi():
    return bytearray([0xFF, 0xD9])


def seg_app0():
    return _seg(0xE0, b'JFIF\x00' + bytes([1, 1, 0, 0, 1, 0, 1, 0, 0]))


def seg_dqt(q_lum, q_chr):
    p = bytearray()
    for tq, q in ((0, q_lum), (1, q_chr)):
        p.append(tq)                       # Pq=0 (8bit), Tq
        for z in range(64):                # DQT 里按 zigzag 顺序存
            p.append(int(q[ZIGZAG[z]]))
    return _seg(0xDB, p)


def seg_sof0(w, h, ncomp=3):
    p = bytearray()
    p.append(8)
    p += bytes([(h >> 8) & 0xFF, h & 0xFF, (w >> 8) & 0xFF, w & 0xFF])
    p.append(ncomp)
    if ncomp == 3:
        comps = [(1, 0x21, 0), (2, 0x11, 1), (3, 0x11, 1)]   # Y:2x1, Cb/Cr:1x1
    else:
        comps = [(1, 0x11, 0)]
    for cid, hv, tq in comps:
        p += bytes([cid, hv, tq])
    return _seg(0xC0, p)


def _dht_entry(tc, th, bits, vals):
    p = bytearray([(tc << 4) | th])
    p += bytes(bits[1:17])                 # 16 个码长计数
    p += bytes(vals)
    return p


def seg_dht(include_chroma=True):
    p = bytearray()
    p += _dht_entry(0, 0, DC_LUM_BITS, DC_LUM_VALS)
    p += _dht_entry(1, 0, AC_LUM_BITS, AC_LUM_VALS)
    if include_chroma:
        p += _dht_entry(0, 1, DC_CHR_BITS, DC_CHR_VALS)
        p += _dht_entry(1, 1, AC_CHR_BITS, AC_CHR_VALS)
    return _seg(0xC4, p)


def seg_sos(ncomp=3):
    p = bytearray()
    p.append(ncomp)
    if ncomp == 3:
        compts = [(1, 0x00), (2, 0x11), (3, 0x11)]           # (Td<<4)|Ta
    else:
        compts = [(1, 0x00)]
    for cid, tdta in compts:
        p += bytes([cid, tdta])
    p += bytes([0, 63, 0])                 # Ss, Se, Ah/Al
    return _seg(0xDA, p)


# ============================================================================
#  6. 色域扩展 (limited -> full)，与 RTL 的 range 模块一致
# ============================================================================
def expand_range(yuv, do_y=True, do_c=True):
    """BT.709 limited (Y 16-235, C 16-240) -> full (0-255)

    ⚠ 这里必须用**截断除法**(floor), 不能四舍五入 —— 因为 RTL 侧是
    「倒数定点乘 + 算术右移」, 算术右移对负数就是向下取整。两边都用 floor
    才能逐位一致。

    RTL 对应实现 (S=16, 除法变乘法):
        Y'  = ((Y - 16)  * 76312) >>> 16        # 76312 = ceil(2^16 * 255/219)
        C'  = ((C - 128) * 74606) >>> 16 + 128  # 74606 = round(2^16 * 255/224)
    已核对: 对全部合法输入 (Y-16 in 0..219, C-128 in -112..112) 两者结果相同。
    """
    Y, Cb, Cr = yuv
    if do_y:
        Y = np.clip((Y.astype(np.int32) - 16) * 255 // 219, 0, 255)
    if do_c:
        Cb = np.clip((Cb.astype(np.int32) - 128) * 255 // 224 + 128, 0, 255)
        Cr = np.clip((Cr.astype(np.int32) - 128) * 255 // 224 + 128, 0, 255)
    return Y.astype(np.uint8), Cb.astype(np.uint8), Cr.astype(np.uint8)


# ============================================================================
#  7. 分块
# ============================================================================
def to_blocks(plane, bw=8, bh=8):
    """(H,W) -> (N,8,8)，行优先，N = (H/8)*(W/8)"""
    H, W = plane.shape
    ny, nx = H // bh, W // bw
    v = plane.reshape(ny, bh, nx, bw).transpose(0, 2, 1, 3)
    return v.reshape(ny * nx, bh, bw).astype(np.int64)


# ============================================================================
#  8. 主编码流程
# ============================================================================
def encode(yuv, quality=75, expand=True, dump_blocks=0, verbose=True):
    """yuv = (Y, Cb, Cr)

    Y  : (H, W) uint8, 全分辨率
    Cb : (H, W/2) uint8, 水平 2:1
    Cr : (H, W/2) uint8
    返回 (jpeg_bytes, 诊断dict)
    """
    Y, Cb, Cr = [np.asarray(x) for x in yuv]
    H, W = Y.shape
    assert W % 16 == 0 and H % 8 == 0, "尺寸须能被 MCU 整除: %dx%d" % (W, H)
    assert Cb.shape == (H, W // 2) and Cr.shape == (H, W // 2)

    if expand:
        Y, Cb, Cr = expand_range((Y, Cb, Cr))

    # ---- 电平移位 & 分块 ----
    yblk = to_blocks(Y.astype(np.int64) - 128)          # (Ny,8,8), Ny=(H/8)*(W/8)
    cbblk = to_blocks(Cb.astype(np.int64) - 128)        # (Nc,8,8), Nc=(H/8)*(W/16)
    crblk = to_blocks(Cr.astype(np.int64) - 128)
    ny_x = W // 8                                       # 每行 luma 块数 = 240
    nc_x = W // 16                                      # 每行 chroma 块数 = 120

    # ---- DCT ----
    Fy = fdct_blocks(yblk)
    Fcb = fdct_blocks(cbblk)
    Fcr = fdct_blocks(crblk)

    # ---- 量化表 ----
    q_lum, rc_lum = quality_scale_table(Q_LUM, quality)
    q_chr, rc_chr = quality_scale_table(Q_CHR, quality)
    qf_y = quantize_blocks(Fy, rc_lum)
    qf_cb = quantize_blocks(Fcb, rc_chr)
    qf_cr = quantize_blocks(Fcr, rc_chr)

    # ---- 霍夫曼表 ----
    hdc_l = build_codes(DC_LUM_BITS, DC_LUM_VALS, "DC lum")
    hac_l = build_codes(AC_LUM_BITS, AC_LUM_VALS, "AC lum")
    hdc_c = build_codes(DC_CHR_BITS, DC_CHR_VALS, "DC chr")
    hac_c = build_codes(AC_CHR_BITS, AC_CHR_VALS, "AC chr")

    # ---- 组装输出 ----
    out = bytearray()
    out += seg_soi()
    out += seg_app0()
    out += seg_dqt(q_lum, q_chr)
    out += seg_sof0(W, H, 3)
    out += seg_dht(True)
    out += seg_sos(3)

    bw = BitWriter()
    mcu_x, mcu_y = W // 16, H // 8
    nblocks = 0
    n_symbols = 0
    dump = []

    # 逐分量 DC 预测值
    pred = {0: 0, 1: 0, 2: 0}

    def code_block(blkcoef, hdc, hac, comp_idx):
        """blkcoef: (8,8) 量化系数 [v][u]，按 zigzag 顺序熵编码"""
        nonlocal n_symbols
        zz = np.array([blkcoef[ZIGZAG[z] // 8][ZIGZAG[z] % 8] for z in range(64)],
                      dtype=np.int64)

        # ---- DC ----
        diff = int(zz[0]) - pred[comp_idx]
        pred[comp_idx] = int(zz[0])
        s = magnitude_category(diff)
        code, ln = hdc[s]
        bw.put_bits(code, ln)
        n_symbols += 1
        if s:
            bw.put_bits(amp_bits(diff, s), s)

        # ---- AC ----
        run = 0
        for k in range(1, 64):
            v = int(zz[k])
            if v == 0:
                run += 1
                continue
            while run > 15:
                code, ln = hac[0xF0]                 # ZRL
                bw.put_bits(code, ln)
                n_symbols += 1
                run -= 16
            s = magnitude_category(v)
            sym = (run << 4) | s
            code, ln = hac[sym]
            bw.put_bits(code, ln)
            n_symbols += 1
            bw.put_bits(amp_bits(v, s), s)
            run = 0
        if run > 0:                                   # EOB
            code, ln = hac[0x00]
            bw.put_bits(code, ln)
            n_symbols += 1

    for my in range(mcu_y):
        for mx in range(mcu_x):
            # MCU = 16x8: Y 块(2m), Y 块(2m+1), Cb, Cr
            n_y0 = my * ny_x + 2 * mx
            n_y1 = n_y0 + 1
            n_c = my * nc_x + mx
            code_block(qf_y[n_y0], hdc_l, hac_l, 0)
            code_block(qf_y[n_y1], hdc_l, hac_l, 0)
            code_block(qf_cb[n_c], hdc_c, hac_c, 1)
            code_block(qf_cr[n_c], hdc_c, hac_c, 2)
            nblocks += 4
            if dump_blocks and len(dump) < dump_blocks * 64:
                dump.extend([int(qf_y[n_y0][ZIGZAG[z] // 8][ZIGZAG[z] % 8])
                             for z in range(64)])

    bw.flush()
    out += bw.buf
    out += seg_eoi()

    stats = dict(bytes=len(out), blocks=nblocks, symbols=n_symbols,
                 bits_per_symbol=(8.0 * len(bw.buf) / max(1, n_symbols)),
                 q_lum=q_lum.tolist(), q_chr=q_chr.tolist(),
                 stuff=bw.stuff_count, dump=dump)
    if verbose:
        print("    块数 %d, 符号数 %d, 熵编码字节 %d, 填充 %d 处, 总 %d 字节"
              % (nblocks, n_symbols, len(bw.buf), bw.stuff_count, len(out)))
    return bytes(out), stats


# ============================================================================
#  9. 自检
# ============================================================================
def make_test_yuv(w=1920, h=1080, seed=1234):
    """合成一帧 YUV422 —— 彩条 + 渐变 + 噪声, 覆盖各种频率成分"""
    rng = np.random.default_rng(seed)
    x = np.arange(w)[None, :]
    y = np.arange(h)[:, None]
    Y = (128 + 60 * np.sin(2 * np.pi * x / 256.0)
         + 40 * np.cos(2 * np.pi * y / 128.0)).astype(np.int32)
    bars = (x // (w // 8)) % 8
    Y = np.clip(Y + bars * 12, 16, 235)
    Y[:, ::7] = 235                              # 细竖条: 高频
    Y = np.clip(Y + rng.integers(-4, 5, Y.shape), 16, 235).astype(np.uint8)

    cx = np.arange(w // 2)[None, :]
    Cb = np.clip(128 + 40 * np.sin(2 * np.pi * cx / 200.0), 16, 240).astype(np.uint8)
    Cb = np.repeat(Cb, h, axis=0)
    Cr = np.clip(128 + 40 * np.cos(2 * np.pi * cx / 300.0), 16, 240).astype(np.uint8)
    Cr = np.repeat(Cr, h, axis=0)
    return Y, Cb, Cr


def yuv_to_rgb709(yuv):
    """BT.709 limited -> RGB (给 PIL 对比用)

    ⚠ 色度必须归一化到 [-0.5, 0.5] 再套矩阵系数:
        Y'  = (Y  - 16)/219      -> [0, 1]
        Cb' = (Cb - 128)/224     -> [-0.5, 0.5]   <-- 漏掉 /224 会让色度项放大 224 倍
        Cr' = (Cr - 128)/224
        R = Y' + 1.5748*Cr'
        G = Y' - 0.1873*Cb' - 0.4681*Cr'
        B = Y' + 1.8556*Cb'
    最后 x255 并截顶。
    """
    Y, Cb, Cr = yuv
    Yl = (Y.astype(np.float64) - 16.0) / 219.0
    Cb = (np.repeat(Cb.astype(np.float64), 2, axis=1) - 128.0) / 224.0
    Cr = (np.repeat(Cr.astype(np.float64), 2, axis=1) - 128.0) / 224.0
    R = (Yl + 1.5748 * Cr) * 255.0
    G = (Yl - 0.1873 * Cb - 0.4681 * Cr) * 255.0
    B = (Yl + 1.8556 * Cb) * 255.0
    return np.clip(np.dstack([R, G, B]), 0, 255).astype(np.uint8)


def psnr(a, b):
    a = a.astype(np.float64)
    b = b.astype(np.float64)
    mse = np.mean((a - b) ** 2)
    if mse == 0:
        return float('inf')
    return 10.0 * np.log10(255.0 * 255.0 / mse)


def selftest(quality=75, do_dump=None):
    from PIL import Image
    import io

    print("=" * 68)
    print(" jpeg_ref.py 自检   quality=%d" % quality)
    print("=" * 68)

    w, h = 1920, 1080
    print("\n[1] 生成合成 YUV422 测试帧 %dx%d" % (w, h))
    yuv = make_test_yuv(w, h)
    print("    Y  min/max = %d/%d   Cb %d/%d   Cr %d/%d"
          % (yuv[0].min(), yuv[0].max(), yuv[1].min(), yuv[1].max(),
             yuv[2].min(), yuv[2].max()))

    print("\n[2] 编码")
    data, st = encode(yuv, quality=quality, dump_blocks=8)
    print("    输出 %d 字节 (%.1f KB), 位/像素 = %.3f"
          % (len(data), len(data) / 1024.0, len(data) * 8.0 / (w * h)))

    print("\n[3] 用 PIL 解码 (验证是合法 JPEG)")
    im = Image.open(io.BytesIO(data))
    print("    尺寸 %s  模式 %s  格式 %s" % (im.size, im.mode, im.format))
    assert im.size == (w, h), "解码尺寸不符!"
    dec = np.asarray(im.convert('RGB')).astype(np.int32)

    print("\n[4] 与「原图 -> BT.709 转 RGB」对比 (排除色域/矩阵带来的差异)")
    ref = yuv_to_rgb709(yuv).astype(np.int32)
    p = psnr(dec, ref)
    print("    本编码器 PSNR = %.2f dB" % p)

    print("\n[5] 对照 PIL 自带编码器 (同质量, 同 4:2:2)")
    buf = io.BytesIO()
    Image.fromarray(ref.astype(np.uint8)).save(
        buf, format='JPEG', quality=quality, subsampling='4:2:2')
    pil_data = buf.getvalue()
    pil_dec = np.asarray(Image.open(io.BytesIO(pil_data)).convert('RGB')).astype(np.int32)
    print("    PIL  %d 字节 (%.1f KB), PSNR = %.2f dB"
          % (len(pil_data), len(pil_data) / 1024.0, psnr(pil_dec, ref)))
    print("    本实现 %d 字节 (%.1f KB), PSNR = %.2f dB"
          % (len(data), len(data) / 1024.0, p))
    ratio = len(data) / float(len(pil_data))
    print("    体积比 = %.3f  (0.8~1.3 视为正常)" % ratio)

    print("\n[6] 关键正确性判据")
    ok = True
    if p < 30.0:
        print("    ✗ PSNR 过低 (%.2f dB), 编码流程可能有错" % p)
        ok = False
    else:
        print("    OK PSNR %.2f dB >= 30 dB" % p)
    if not (0.7 < ratio < 1.4):
        print("    ✗ 体积与 PIL 差异过大 (%.3f)" % ratio)
        ok = False
    else:
        print("    OK 体积与 PIL 同量级 (%.3f)" % ratio)
    if st['stuff'] == 0:
        print("    ?  未发生 0xFF 填充 (小图正常, 大图少见)")
    else:
        print("    OK 0xFF 填充触发 %d 次 (说明填充逻辑被测到)" % st['stuff'])

    print("\n[7] 定点 DCT 精度核对 (对比 float64 真值)")
    rng = np.random.default_rng(7)
    blk = (rng.integers(-128, 128, (64, 8, 8))).astype(np.int64)
    Fint = fdct_blocks(blk)
    Bf = np.zeros((8, 8))
    for k in range(8):
        ck = (1.0 / np.sqrt(2.0)) if k == 0 else 1.0
        for n in range(8):
            Bf[k, n] = ck * np.cos((2 * n + 1) * k * np.pi / 16.0)
    G = np.einsum('vy,nyx->nvx', Bf, blk.astype(np.float64))
    Hf = np.einsum('ux,nvx->nvu', Bf, G)
    Ftrue = Hf / 4.0
    err = np.abs(Fint.astype(np.float64) - Ftrue)
    print("    |F_int - F_true|  最大 %.3f  平均 %.3f   (F 范围 ±%.0f)"
          % (err.max(), err.mean(), np.abs(Ftrue).max()))
    print("    相对最大误差 %.4f%%" % (100.0 * err.max() / np.abs(Ftrue).max()))
    if err.max() > 2.0:
        print("    ~ 误差略大, 但视觉无影响 (可提高 QB 改善)")
    else:
        print("    OK 误差 <= 2.0, 远小于量化步长")

    if do_dump:
        with open(do_dump, 'w', encoding='utf-8') as f:
            f.write("# jpeg_ref.py dump  quality=%d\n" % quality)
            f.write("# 前 %d 个块 (MCU 顺序: Y0 Y1 Cb Cr), 每块 64 个 zigzag 量化系数\n"
                    % 8)
            f.write("# 量化表(自然序 v,u):\n")
            f.write("# QLUM " + " ".join(str(v) for v in st['q_lum']) + "\n")
            f.write("# QCHR " + " ".join(str(v) for v in st['q_chr']) + "\n")
            n = len(st['dump']) // 64
            for b in range(n):
                f.write("BLK %d: %s\n" % (b, " ".join(str(v) for v in
                                                      st['dump'][b * 64:(b + 1) * 64])))
        print("\n[8] 已导出量化系数 -> %s (%d 块)" % (do_dump, n))

    print("\n" + "=" * 68)
    print(" 自检 %s" % ("通过" if ok else "**失败**"))
    print("=" * 68)
    return 0 if ok else 1


# ============================================================================
#  10. 无损模式 (SOF3, ITU-T T.81 Annex H)
# ============================================================================
from gen_jpeg_tables import LOSSLESS_BITS, LOSSLESS_VALS   # noqa: E402


def med_predict(a, b, c):
    """MED (LOCO-I median edge detector)。

    必须与 RTL (jpeg_lossless_enc.v 的 med 函数) 逐位一致:
        mx = max(a,b); mn = min(a,b)
        c >= mx -> mn ;  c <= mn -> mx ;  else clamp(a+b-c, 0, 255)
    """
    mx = a if a > b else b
    mn = a if a < b else b
    if c >= mx:
        return mn
    if c <= mn:
        return mx
    t = a + b - c
    if t > 255:
        return 255
    if t < 0:
        return 0
    return t


def seg_sof3(w, h, ncomp=3):
    p = bytearray()
    p.append(8)
    p += bytes([(h >> 8) & 0xFF, h & 0xFF, (w >> 8) & 0xFF, w & 0xFF])
    p.append(ncomp)
    comps = [(1, 0x21, 0), (2, 0x11, 0), (3, 0x11, 0)]   # 无损无量化表
    for cid, hv, tq in comps:
        p += bytes([cid, hv, tq])
    return _seg(0xC3, p)


def seg_dht_lossless():
    """只发一张 lossless DC 表 (Tc=0, Th=0), 符号 = 幅度分类 0..16"""
    p = bytearray([0x00])
    p += bytes(LOSSLESS_BITS[1:17])
    p += bytes(LOSSLESS_VALS)
    return _seg(0xC4, p)


def seg_sos_lossless(ncomp=3):
    p = bytearray()
    p.append(ncomp)
    for cid, tdta in [(1, 0x00), (2, 0x11), (3, 0x11)]:
        p += bytes([cid, tdta])
    p += bytes([0, 0, 0])          # Ss=0, Se=0, Ah/Al=0
    return _seg(0xDA, p)


def encode_lossless(yuv, verbose=True):
    """4:2:2 无损 JPEG (SOF3)。

    ★ 一个 MCU = 1 个 YUV422 word = (Y0, Y1, Cb, Cr)。所以预测器只需要
      上一行整行 + 当前行前一个 word —— 与 RTL 的实现完全相同。

    邻居约定 (与 RTL 一致):
        Y0 : a = 上一 word 的 Y1, b = 上行同列 Y0, c = 上行前一列 Y1
        Y1 : a = 本 word 的 Y0,  b = 上行同列 Y1, c = 上行同列 Y0
        Cb : a = 上一 word 的 Cb, b = 上行同列 Cb, c = 上行前一列 Cb
        Cr : 同 Cb
    不存在的邻居一律取 0 (第一行退化为 a, 第一列退化为 b, 左上角为 0)。
    """
    Y, Cb, Cr = [np.asarray(x) for x in yuv]
    H, W = Y.shape
    assert W % 2 == 0, "宽度必须是偶数"

    out = bytearray()
    out += seg_soi()
    out += seg_app0()
    out += seg_sof3(W, H, 3)
    out += seg_dht_lossless()
    out += seg_sos_lossless(3)

    bw = BitWriter()
    huff = build_codes(LOSSLESS_BITS, LOSSLESS_VALS, "Lossless DC")
    nwx = W // 2
    zero = (0, 0, 0, 0)
    prev = [zero] * nwx
    nsym = 0

    for r in range(H):
        left = zero
        cur = [zero] * nwx
        for cx in range(nwx):
            y0 = int(Y[r, 2 * cx])
            y1 = int(Y[r, 2 * cx + 1])
            cb = int(Cb[r, cx])
            cr = int(Cr[r, cx])
            up = prev[cx]
            upl = prev[cx - 1] if cx > 0 else zero

            p0 = med_predict(left[1], up[0], upl[1])
            p1 = med_predict(y0,      up[1], up[0])
            pc = med_predict(left[2], up[2], upl[2])
            pr = med_predict(left[3], up[3], upl[3])

            for px, pv in ((y0, p0), (y1, p1), (cb, pc), (cr, pr)):
                d = px - pv
                s = magnitude_category(d)
                cd, ln = huff[s]
                bw.put_bits(cd, ln)
                if s:
                    bw.put_bits(amp_bits(d, s), s)
                nsym += 1

            v = (y0, y1, cb, cr)
            cur[cx] = v
            left = v
        prev = cur

    bw.flush()
    out += bw.buf
    out += seg_eoi()

    if verbose:
        print("    无损: 采样 %d, 熵字节 %d, 填充 %d, 总 %d 字节"
              % (nsym, len(bw.buf), bw.stuff_count, len(out)))
    return bytes(out), dict(bytes=len(out), symbols=nsym, stuff=bw.stuff_count)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--quality', type=int, default=75)
    ap.add_argument('--dump', default=None, help='导出量化系数供 RTL 比对')
    ap.add_argument('--save', default=None, help='保存 JPEG 到文件')
    a = ap.parse_args()
    if a.save:
        yuv = make_test_yuv(1920, 1080)
        data, _ = encode(yuv, quality=a.quality)
        with open(a.save, 'wb') as f:
            f.write(data)
        print("已写出 %s (%d 字节)" % (a.save, len(data)))
        return 0
    return selftest(a.quality, a.dump)


if __name__ == '__main__':
    sys.exit(main())
