#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
lz77_ref.py —— FPGA LZ77 (YUV 域) 压缩器的黄金模型

★ 这是 RTL 的唯一契约: jpeg_lz77.v 必须逐字节一致。

设计为什么长这样
----------------
目标是"无损压缩原始 YUV 流"(bypass 直通模式) 以降低 CSI-2 带宽, 而不是
压在 JPEG 码流上 (JPEG 已经是熵编码, 再套 LZ77 收益很低)。

硬件友好约束 —— 每一条都是为了 RTL 能用几十行状态机实现出来:

  * 窗口 16 KB (offset 14 位), 哈希表 2^11 项, 每项存"窗口内相对位置"
  * 单候选匹配: 每个位置只查一次哈希、只比较一个候选 (不做链式搜索)
    这是 LZ4 的做法。多候选能把压缩率再提几个点, 但需要多趟比较,
    在 147.5 MHz 的实时流里不划算。
  * literal run 最长 15 (不设扩展字节), match 长度 4..18 (4 + 0..15)
    —— 这样每个记录固定只有 1 字节 header, 编解码都不用变长整数。
  * 匹配长度上限 18 也是为了让"逐字节比较"最多 18 拍就结束。

记录格式 (每条记录 = 1 字节 header + 可选载荷)
----------------------------------------------
    header = (litlen << 4) | (mlen - 3)       litlen 0..15, mlen 4..18
    载荷   = litlen 个 literal 字节
             若 mlen 字段 != 0, 再跟 2 字节小端 offset (1..16384)

    header == 0x00 且后面没有载荷  -> 流结束 (EOF)

为什么 match 字段存 mlen-3 而不是 LZ4 的 mlen-4: mlen-4 在 mlen==4
时会算出 0, 而 0 已经用来表示"本条无匹配", 两者撞车 —— 实测末尾一个
4 字节匹配会被解码器当成 EOF, 输出直接少 4 字节。存 mlen-3 之后
mlen 4..18 对应字段 1..15, 0 干净地留给"无匹配"和 EOF。
"""

import sys
import os

WIN      = 16384          # 窗口大小 = 最大 offset
HBITS    = 11
HSIZE    = 1 << HBITS
MAXLIT   = 15             # 单条记录的 literal 上限
MINMATCH = 4
MAXMATCH = 18             # 4 + 14, 字段存 mlen-3 所以最大 15

EOF_HDR = 0x00


def _hash(buf, p):
    """3 字节哈希, 与 RTL 里 h = b0*1024 ^ b1*32 ^ b2 保持一致。"""
    return ((buf[p] << 10) ^ (buf[p + 1] << 5) ^ buf[p + 2]) & (HSIZE - 1)


def _match_len(buf, a, b, limit):
    """从 a/b 两处起算公共前缀长度, 最多 limit 字节。"""
    n = 0
    while n < limit and buf[a + n] == buf[b + n]:
        n += 1
    return n


def compress(src, verbose=False):
    """把字节流 src 压成 LZ77 记录流, 返回 bytes。"""
    n = len(src)
    out = bytearray()
    ht = [-1] * HSIZE
    lit_start = 0
    p = 0
    nrec = 0
    nlit = 0
    nmatch = 0

    def emit_literals(upto, mlen4, offset):
        """把 [lit_start, upto) 的 literal 按 15 字节一段切开输出,
        最后一段带上 mlen4 / offset。"""
        nonlocal lit_start, nrec, nlit, nmatch
        while upto - lit_start > MAXLIT:
            out.append((MAXLIT << 4) | 0)
            out.extend(src[lit_start:lit_start + MAXLIT])
            nrec += 1
            nlit += MAXLIT
            lit_start += MAXLIT
        litlen = upto - lit_start
        out.append((litlen << 4) | mlen4)
        out.extend(src[lit_start:upto])
        nrec += 1
        nlit += litlen
        if mlen4:
            out.append(offset & 0xFF)
            out.append((offset >> 8) & 0xFF)
            nmatch += 1

    while p < n:
        if p + MINMATCH <= n:
            h = _hash(src, p)
            cand = ht[h]
            ht[h] = p
            if cand >= 0 and (p - cand) <= WIN:
                # 匹配长度不能越过缓冲区末尾
                limit = min(MAXMATCH, n - p)
                ml = _match_len(src, cand, p, limit)
                if ml >= MINMATCH:
                    emit_literals(p, ml - 3, p - cand)
                    # 把匹配覆盖到的中间位置也登记进哈希表, 提升后续命中率
                    for q in range(p + 1, min(p + ml, n - MINMATCH + 1)):
                        ht[_hash(src, q)] = q
                    p += ml
                    lit_start = p
                    continue
        p += 1

    # 收尾: 剩余 literal + EOF 记录
    emit_literals(n, 0, 0)
    out.append(EOF_HDR)
    nrec += 1

    if verbose:
        print("  LZ77: %d -> %d 字节 (%.1f%%), 记录 %d, literal %d, match %d"
              % (n, len(out), 100.0 * len(out) / max(n, 1), nrec, nlit, nmatch))
    return bytes(out)


def decompress(data, limit=1 << 26):
    """参考解码器 —— 用来验证 compress() 自洽, 也是 RK 侧解压实现的依据。"""
    out = bytearray()
    i = 0
    while i < len(data):
        hdr = data[i]; i += 1
        litlen = (hdr >> 4) & 0xF
        mlen4 = hdr & 0xF
        if litlen == 0 and mlen4 == 0:
            break                       # EOF
        if litlen:
            out.extend(data[i:i + litlen])
            i += litlen
        if mlen4:
            off = data[i] | (data[i + 1] << 8); i += 2
            if off == 0:
                raise ValueError("offset 0 非法")
            src = len(out) - off
            if src < 0:
                raise ValueError("offset %d 越过起点" % off)
            ml = mlen4 + 3
            # 逐字节复制: 允许重叠 (RLE 情形)
            for k in range(ml):
                out.append(out[src + k])
        if len(out) > limit:
            raise ValueError("解压超过上限")
    return bytes(out)


# ---------------------------------------------------------------- 自测
def _make_yuv_like(w, h):
    """造一段和真实 YUV422 统计特性接近的数据: 大片平坦 + 渐变 + 少量噪声。"""
    import numpy as np
    y = np.zeros((h, w), np.uint8)
    for r in range(h):
        for c in range(w):
            base = int(40 + 120 * (c / max(w - 1, 1)))
            y[r, c] = (base + (r * 3) % 40) & 0xFF
    y[h // 3: 2 * h // 3, w // 4: 3 * w // 4] = 200        # 纯色块
    rng = np.random.RandomState(7)
    y += rng.randint(0, 6, y.shape).astype(np.uint8)
    cb = np.full((h, w // 2), 128, np.uint8)
    cr = np.full((h, w // 2), 128, np.uint8)
    out = bytearray()
    for r in range(h):
        for c in range(w // 2):
            out += bytes((y[r, 2 * c], cb[r, c], y[r, 2 * c + 1], cr[r, c]))
    return bytes(out)


def selftest(w=1920, h=1080):
    src = _make_yuv_like(w, h)
    comp = compress(src, verbose=True)
    back = decompress(comp)
    ok = (back == src)
    print("  %dx%d: 原 %d B, 压后 %d B, 往返 %s"
          % (w, h, len(src), len(comp), "一致" if ok else "★不一致★"))
    return 0 if ok else 1


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        w = int(sys.argv[2]) if len(sys.argv) > 2 else 320
        h = int(sys.argv[3]) if len(sys.argv) > 3 else 40
        return selftest(w, h)
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
