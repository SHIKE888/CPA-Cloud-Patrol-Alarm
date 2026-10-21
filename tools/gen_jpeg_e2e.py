#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_jpeg_e2e.py —— 端到端仿真的输入/参考输出

生成:
    fpga/sim/jpeg_in.hex   —— 每行一个 32bit YUV422 word {Cr,Y1,Cb,Y0}, $readmemh 喂给 tb
    fpga/sim/ref.jpg       —— jpeg_ref.py 在同一份 YUV 上的输出 (逐字节基准)

用法:
    python tools/gen_jpeg_e2e.py [W] [H]

注意:
    * 尺寸必须满足 W%16==0 且 H%8==0 (MCU 16x8 无缝整除)
    * quality 固定 50 —— 此时 quality_scale_table 的 scale=100,
      Q 表就是 Annex K.1 标准表, 与 jpeg_qtable_ram 的复位值一致。
    * expand=False —— 本仿真的 YUV 本身就是 full range (0..255),
      不经过 jpeg_range。真机上 limited->full 由 jpeg_range 完成。
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from jpeg_ref import encode          # noqa: E402

SIM = os.path.normpath(os.path.join(HERE, "..", "fpga", "sim"))


def make_yuv(w, h, seed=2026):
    rng = np.random.default_rng(seed)
    x = np.arange(w)[None, :]
    y = np.arange(h)[:, None]

    Y = (128 + 55 * np.sin(2 * np.pi * x / 32.0)
         + 35 * np.cos(2 * np.pi * y / 12.0))
    bars = (x // (w // 8)) % 8
    Y = Y + bars * 10
    Y[:, ::5] = 240                        # 高频竖条
    Y = np.clip(Y + rng.integers(-3, 4, Y.shape), 0, 255).astype(np.uint8)

    cx = np.arange(w // 2)[None, :]
    Cb = np.clip(128 + 45 * np.sin(2 * np.pi * cx / 17.0), 0, 255).astype(np.uint8)
    Cr = np.clip(128 + 45 * np.cos(2 * np.pi * cx / 23.0), 0, 255).astype(np.uint8)
    Cb = np.repeat(Cb, h, axis=0)
    Cr = np.repeat(Cr, h, axis=0)
    return Y, Cb, Cr


def main():
    w = int(sys.argv[1]) if len(sys.argv) > 1 else 64
    h = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    assert w % 16 == 0 and h % 8 == 0, "W 必须是 16 的倍数, H 必须是 8 的倍数"

    Y, Cb, Cr = make_yuv(w, h)

    # --- 打包成 YUV422 word: {Cr, Y1, Cb, Y0} ---
    lines = []
    for r in range(h):
        for c in range(w // 2):
            y0 = int(Y[r, 2 * c])
            y1 = int(Y[r, 2 * c + 1])
            cb = int(Cb[r, c])
            cr = int(Cr[r, c])
            lines.append("%08x" % (((cr << 24) | (y1 << 16) | (cb << 8) | y0)))

    p_in = os.path.join(SIM, "jpeg_in.hex")
    with open(p_in, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    # --- 参考编码 ---
    data, st = encode((Y, Cb, Cr), quality=50, expand=False, verbose=False)
    p_ref = os.path.join(SIM, "ref.jpg")
    with open(p_ref, "wb") as f:
        f.write(data)

    import hashlib
    print("W=%d H=%d  MCU=%dx%d" % (w, h, w // 16, h // 8))
    print("wrote %s : %d words" % (p_in, len(lines)))
    print("wrote %s : %d bytes  md5=%s"
          % (p_ref, len(data), hashlib.md5(data).hexdigest()))
    print("  blocks=%d symbols=%d entropy_bytes=%d stuff=%d"
          % (st['blocks'], st['symbols'], len(data) - 607 - 2, st['stuff']))
    print("  预期 RTL 总字节 = 607(头) + %d(熵) + 2(EOI) = %d"
          % (len(data) - 609, len(data)))


if __name__ == "__main__":
    main()
