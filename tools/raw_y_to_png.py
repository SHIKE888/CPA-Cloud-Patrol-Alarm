#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把裸数据里的亮度(Y)写成 PNG, 不依赖 PIL/numpy。

用法:
    python raw_y_to_png.py <in.raw> <out.png> <width> <height> [scale] [step] [offset]

step/offset 用于从交错格式里抽 Y:
    YUYV422 (YUYV8_2X8) : Y 在偶数字节  -> step=2 offset=0
    UYVY422             : Y 在奇数字节  -> step=2 offset=1
    已 planar (NV16 的 Y 平面)          -> step=1 offset=0
"""
import struct
import sys
import zlib

step_g, off_g = 1, 0


def write_gray_png(path, w, h, data, scale=1):
    W, H = (w + scale - 1) // scale, (h + scale - 1) // scale
    raw = bytearray()
    stride = w * scale
    for oy in range(H):
        y0 = oy * stride
        raw.append(0)                                  # filter: none
        row = data[y0:y0 + w:scale]                    # 横向抽样
        if len(row) < W:                               # 末行补齐
            row = row + bytes(W - len(row))
        raw += row
    def chunk(typ, dat):
        return (struct.pack('>I', len(dat)) + typ + dat +
                struct.pack('>I', zlib.crc32(typ + dat) & 0xFFFFFFFF))
    ihdr = struct.pack('>IIBBBBB', W, H, 8, 0, 0, 0, 0)   # 8bit 灰度
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', ihdr))
        f.write(chunk(b'IDAT', zlib.compress(bytes(raw), 6)))
        f.write(chunk(b'IEND', b''))
    print("  -> %s  %dx%d  (scale=%d step=%d off=%d)" % (path, W, H, scale, step_g, off_g))


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 1
    src, dst, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    scale = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    global step_g, off_g
    step_g = int(sys.argv[6]) if len(sys.argv) > 6 else 1
    off_g = int(sys.argv[7]) if len(sys.argv) > 7 else 0
    need = w * h * step_g + off_g
    d = open(src, 'rb').read(need)
    print("读入 %d 字节 (期望 %d)" % (len(d), need))
    y = d[off_g::step_g][:w * h]
    write_gray_png(dst, w, h, bytes(y), scale)
    return 0


if __name__ == '__main__':
    sys.exit(main())
