#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_dct_vec.py —— 生成 jpeg_dct2d 的仿真向量 (输入块 + Python 参考输出)

输出格式 (每行一个 32bit hex, 供 $readmemh):
    块 0 输入 64 个 (16bit 二补码, 范围 -128..127)
    块 0 期望 64 个 (18bit 二补码)
    块 1 输入 64 个
    块 1 期望 64 个
    ...

块的存储顺序与 RTL 一致: blk[v*8+u] = 第 v 行第 u 列, v/u 都是 0..7
期望输出顺序: F[k*8+v], 其中 k = 垂直频率, v = 水平频率
    (与 jpeg_ref.fdct_blocks 返回的 [n][v][u] 对应: k->v, v->u)
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from jpeg_ref import fdct_blocks     # noqa: E402

OUT = os.path.join(HERE, "dct_vec.hex")


def masks():
    """几组能暴露不同问题的图案, 加若干随机块"""
    blocks = []
    # 1) 全零 -> 输出必须全零
    blocks.append(np.zeros((8, 8), dtype=np.int64))
    # 2) 平坦 DC (全 100)
    blocks.append(np.full((8, 8), 100, dtype=np.int64))
    # 3) 水平渐变
    blocks.append(np.tile(np.arange(8) * 16 - 56, (8, 1)).astype(np.int64))
    # 4) 垂直渐变
    blocks.append(np.tile((np.arange(8) * 16 - 56)[:, None], (1, 8)).astype(np.int64))
    # 5) 棋盘 (最高频)
    yy, xx = np.mgrid[0:8, 0:8]
    blocks.append(np.where((yy + xx) % 2 == 0, 100, -100).astype(np.int64))
    # 6) 单点冲激
    b = np.zeros((8, 8), dtype=np.int64)
    b[0, 0] = 127
    blocks.append(b)
    # 7) 全 -128 (最小值)
    blocks.append(np.full((8, 8), -128, dtype=np.int64))
    # 8) 全 +127
    blocks.append(np.full((8, 8), 127, dtype=np.int64))
    # 9..16) 随机
    rng = np.random.default_rng(20261021)
    for _ in range(8):
        blocks.append(rng.integers(-128, 128, (8, 8), dtype=np.int64))
    return blocks


def main():
    blks = np.stack(masks(), axis=0)                 # (N,8,8)
    F = fdct_blocks(blks)                            # (N,8,8) [n][v][u]

    lines = []
    for n in range(blks.shape[0]):
        for v in range(8):
            for u in range(8):
                lines.append("%08x" % (int(blks[n, v, u]) & 0xFFFF))
        for k in range(8):
            for v in range(8):
                # RTL 输出顺序 F[k*8+v], 其中 k=垂直频率(v 索引), v=水平频率(u 索引)
                lines.append("%08x" % (int(F[n, k, v]) & 0x3FFFF))

    with open(OUT, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print("wrote %s : %d blocks, %d lines" % (OUT, blks.shape[0], len(lines)))
    print("块 0 (全零)  期望全 0")
    print("块 1 (全 100) F[0][0] = %d, 其余应为 0" % F[1, 0, 0])
    print("块 6 (全-128) F[0][0] = %d" % F[6, 0, 0])
    print("块 7 (全+127) F[0][0] = %d" % F[7, 0, 0])
    print("最大绝对值 = %d" % int(np.abs(F).max()))


if __name__ == "__main__":
    main()
