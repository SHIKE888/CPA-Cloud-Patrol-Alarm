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
    LOSSLESS_BITS, LOSSLESS_VALS,
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


def build_ll():
    """无损 (SOF3) 头部。

    与有损的区别:
      * 标记是 SOF3 (0xC3) 而不是 SOF0
      * **没有 DQT 段** (不做 DCT/量化)
      * DHT 只有一张 lossless DC 表 (tc=0, th=0), 17 个符号 0..16
      * SOS 的 Ss=Se=0, 表示 lossless 过程
    """
    rom = bytearray()
    off = {}

    rom += bytearray([0xFF, 0xD8])
    rom += _seg(0xE0, b'JFIF\x00' + bytes([1, 1, 0, 0, 1, 0, 1, 0, 0]))

    # SOF3 (Tq 字段必须全 0 —— 无损模式不使用量化表)
    rom += bytearray([0xFF, 0xC3, 0x00, 0x11, 0x08])
    off['h'] = len(rom)
    rom += bytearray(2)
    off['w'] = len(rom)
    rom += bytearray(2)
    rom += bytearray([0x03, 0x01, 0x21, 0x00, 0x02, 0x11, 0x00,
                      0x03, 0x11, 0x00])

    # DHT: 只有 lossless DC
    p = bytearray([0x00])                      # Tc=0, Th=0
    p += bytes(LOSSLESS_BITS[1:17])
    p += bytes(LOSSLESS_VALS)
    dht = _seg(0xC4, p)
    off['dht'] = len(rom)
    rom += dht

    # SOS: Ss=0, Se=0
    sos = _seg(0xDA, bytes([0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11,
                            0x00, 0x00, 0x00]))
    off['sos'] = len(rom)
    rom += sos

    return rom, off


def main():
    rom, off = build()
    romll, offll = build_ll()

    def emit(path, rom, off, tag):
        lines = []
        lines.append("//==============================================================================")
        lines.append("//  %s" % os.path.basename(path))
        lines.append("//  JPEG 固定头部字节 ROM —— **由 tools/gen_jpeg_hdr_rom.py 自动生成, 请勿手改**")
        lines.append("//")
        lines.append("//  总长 %d 字节。可变位置 (ROM 里填 0 占位, RTL 输出时替换):" % len(rom))
        for k in ("qy", "qc", "h", "w"):
            if k in off:
                lines.append("//     %s @ %d" % (k, off[k]))
        lines.append("//==============================================================================")
        lines.append("")
        lines.append("function [7:0] %s;" % tag)
        lines.append("    input [9:0] a;")
        lines.append("    begin")
        lines.append("        case (a)")
        for i, v in enumerate(rom):
            lines.append("        10'd%-4d: %s = 8'h%02X;" % (i, tag, v))
        lines.append("        default: %s = 8'h00;" % tag)
        lines.append("        endcase")
        lines.append("    end")
        lines.append("endfunction")
        lines.append("")
        return "\n".join(lines)

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(emit(OUT, rom, off, "jpeg_hdr_rom"))

    out_ll = OUT.replace("jpeg_hdr_rom.vh", "jpeg_hdr_ll.vh")
    with open(out_ll, "w", encoding="utf-8", newline="\n") as f:
        f.write(emit(out_ll, romll, offll, "jpeg_hdr_ll"))

    print("wrote %s : %d bytes  QY=%d QC=%d H=%d W=%d" %
          (OUT, len(rom), off['qy'], off['qc'], off['h'], off['w']))
    print("wrote %s : %d bytes  H=%d W=%d" %
          (out_ll, len(romll), offll['h'], offll['w']))
    print("  LL 头部: SOI+APP0=%d SOF3 头=%d DHT=%d SOS=%d" %
          (20, 5, len(romll) - offll['dht'], 14))


if __name__ == "__main__":
    main()
