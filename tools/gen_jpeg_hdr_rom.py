#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_jpeg_hdr_rom.py —— 生成 jpeg_headers.v 用的固定头部字节 ROM

ROM 布局 (与 jpeg_headers.v 的 cnt 一一对应, 偏移由本脚本动态算出):
    SOI + APP0                     全固定
    FF DB 00 84 00                 DQT 头 + Tq=0
    ★ 64 个 zigzag 序亮度 Q        可变 (运行时从 qtable 读)
    01                             Tq=1
    ★ 64 个 zigzag 序色度 Q        可变
    FF C0 00 11 08                 SOF0 头
    ★ 高度 H (大端)                可变
    ★ 宽度 W (大端)                可变
    03 01 21 00 02 11 01 03 11 01  SOF0 尾
    DHT                            全固定
    SOS                            全固定

可变位置的字节在 ROM 里填 0 (占位), RTL 输出时用真值替换。
本脚本把各段偏移写进生成文件的头部注释, RTL 里的常量必须与之一致。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from gen_jpeg_tables import (      # noqa: E402
    DC_LUM_BITS, DC_LUM_VALS, DC_CHR_BITS, DC_CHR_VALS,
    AC_LUM_BITS, AC_LUM_VALS, AC_CHR_BITS, AC_CHR_VALS,
)

OUT = os.path.normpath(os.path.join(
    HERE, "..", "fpga", "uisrc", "01_rtl", "jpeg", "jpeg_hdr_rom.vh"))


def _seg(marker, payload):
    out = bytearray([0xFF, marker])
    ln = len(payload) + 2
    out += bytes([(ln >> 8) & 0xFF, ln & 0xFF])
    out += payload
    return out


def _dht_entry(tc, th, bits, vals):
    p = bytearray([(tc << 4) | th])
    p += bytes(bits[1:17])
    p += bytes(vals)
    return p


def build():
    rom = bytearray()
    off = {}

    # ---- SOI + APP0 ----
    rom += bytearray([0xFF, 0xD8])
    rom += _seg(0xE0, b'JFIF\x00' + bytes([1, 1, 0, 0, 1, 0, 1, 0, 0]))

    # ---- DQT ----
    rom += bytearray([0xFF, 0xDB, 0x00, 0x84, 0x00])
    off['qy'] = len(rom)
    rom += bytearray(64)                       # 占位: 亮度 Q
    rom += bytearray([0x01])
    off['qc'] = len(rom)
    rom += bytearray(64)                       # 占位: 色度 Q

    # ---- SOF0 ----
    rom += bytearray([0xFF, 0xC0, 0x00, 0x11, 0x08])
    off['h'] = len(rom)
    rom += bytearray(2)                        # 占位: H
    off['w'] = len(rom)
    rom += bytearray(2)                        # 占位: W
    rom += bytearray([0x03, 0x01, 0x21, 0x00, 0x02, 0x11, 0x01,
                      0x03, 0x11, 0x01])

    # ---- DHT ----
    p = bytearray()
    p += _dht_entry(0, 0, DC_LUM_BITS, DC_LUM_VALS)
    p += _dht_entry(1, 0, AC_LUM_BITS, AC_LUM_VALS)
    p += _dht_entry(0, 1, DC_CHR_BITS, DC_CHR_VALS)
    p += _dht_entry(1, 1, AC_CHR_BITS, AC_CHR_VALS)
    dht = _seg(0xC4, p)
    assert len(dht) == 420, len(dht)
    off['dht'] = len(rom)
    rom += dht

    # ---- SOS ----
    sos = _seg(0xDA, bytes([0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11,
                            0x00, 0x3F, 0x00]))
    assert len(sos) == 14, len(sos)
    off['sos'] = len(rom)
    rom += sos

    return rom, off


def main():
    rom, off = build()
    lines = []
    lines.append("//==============================================================================")
    lines.append("//  jpeg_hdr_rom.vh")
    lines.append("//  JPEG 固定头部字节 ROM —— **由 tools/gen_jpeg_hdr_rom.py 自动生成, 请勿手改**")
    lines.append("//")
    lines.append("//  总长 %d 字节。可变位置 (ROM 里填 0 占位, RTL 输出时替换):" % len(rom))
    lines.append("//     亮度 Q  zigzag 序 64 项 @ %d..%d" % (off['qy'], off['qy'] + 63))
    lines.append("//     色度 Q  zigzag 序 64 项 @ %d..%d" % (off['qc'], off['qc'] + 63))
    lines.append("//     高度 H (大端)          @ %d..%d" % (off['h'], off['h'] + 1))
    lines.append("//     宽度 W (大端)          @ %d..%d" % (off['w'], off['w'] + 1))
    lines.append("//     DHT 段起始 = %d,  SOS 段起始 = %d" % (off['dht'], off['sos']))
    lines.append("//")
    lines.append("//  jpeg_headers.v 里的 HDR_LEN / OFF_QY / OFF_QC / OFF_H / OFF_W 必须与上面一致。")
    lines.append("//==============================================================================")
    lines.append("")
    lines.append("function [7:0] jpeg_hdr_rom;")
    lines.append("    input [9:0] a;")
    lines.append("    begin")
    lines.append("        case (a)")
    for i, v in enumerate(rom):
        lines.append("        10'd%-4d: jpeg_hdr_rom = 8'h%02X;" % (i, v))
    lines.append("        default: jpeg_hdr_rom = 8'h00;")
    lines.append("        endcase")
    lines.append("    end")
    lines.append("endfunction")
    lines.append("")

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))

    print("wrote %s" % OUT)
    print("  总长 %d 字节" % len(rom))
    print("  OFF_QY=%d  OFF_QC=%d  OFF_H=%d  OFF_W=%d  OFF_DHT=%d  OFF_SOS=%d"
          % (off['qy'], off['qc'], off['h'], off['w'], off['dht'], off['sos']))


if __name__ == "__main__":
    main()
