#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_jpeg_tables.py —— 从 JPEG 规范(ITU-T T.81) 的原始表定义生成本工程的表文件

为什么要用脚本生成:
    霍夫曼表有 5 张共 400 多个码字。手敲进 Verilog 几乎必错，而且错了很难查。
    这里只输入规范里原始的 (bits[], huffval[]) —— 也就是"每个码长有几个码字、
    码字按顺序对应哪些符号", 码字本身由脚本按规范算法(Annex C 的 canonical
    Huffman 生成)算出来, 并做 **Kraft 不等式自校验**, 确保是合法前缀码。

输出:
    fpga/uisrc/01_rtl/jpeg/jpeg_defs.vh   Verilog 头文件(localparam + 查表函数)
    同时打印校验信息

用法:
    python tools/gen_jpeg_tables.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_VH = os.path.normpath(os.path.join(
    HERE, "..", "fpga", "uisrc", "01_rtl", "jpeg", "jpeg_defs.vh"))

# ============================================================================
#  ITU-T T.81 Annex K.1 —— 量化表 (质量 50 的基准表)
# ============================================================================
Q_LUM = [
    16, 11, 10, 16, 24, 40, 51, 61,
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77,
    24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
]

Q_CHR = [
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 26, 66, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
]

# ============================================================================
#  ITU-T T.81 Annex K.3 —— 霍夫曼表
#  bits[i] (i=1..16) = 长度为 i 的码字个数;  huffval = 按码长递增、同码长按
#  码值递增顺序排列的符号列表
# ============================================================================

# 注意: bits 统一写成 **17 个元素**(index 0 恒为 0 占位, index i = 码长 i 的码字数),
# 这样代码里能直接用 bits[length], 与规范的 BITS[1..16] 一一对应。

# K.3.3.1 Table K.3 —— DC 差分(亮度), 符号 = 幅度分类 SSSS 0..11
DC_LUM_BITS = [0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
DC_LUM_VALS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

# K.3.3.2 Table K.4 —— DC 差分(色度)
DC_CHR_BITS = [0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
DC_CHR_VALS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

# K.3.3.3 Table K.5 —— AC 系数(亮度)
AC_LUM_BITS = [0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
AC_LUM_VALS = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
    0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
    0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16,
    0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
    0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
    0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
    0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
    0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4,
    0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
    0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
]

# K.3.3.4 Table K.6 —— AC 系数(色度)
AC_CHR_BITS = [0, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
AC_CHR_VALS = [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
    0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
    0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34,
    0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
    0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
    0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
    0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
    0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
    0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2,
    0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
    0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9,
    0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
]

# Table K.3 (Annex H 无损模式) —— DC 无损, 符号 = 幅度分类 0..16
LOSSLESS_BITS = [0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0]
LOSSLESS_VALS = list(range(17))

# zigzag 扫描顺序: zigzag 序号 -> 自然(行优先)序号
ZIGZAG = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
]

# AAN (Arai-Agui-Nakajima) 1 维 DCT 常数, Q15 定点
AAN_Q = 15
AAN_ONE = 1 << AAN_Q


def q15(x):
    return int(round(x * AAN_ONE))


AAN_C = {
    "C1": q15(0.98078528),   # cos(pi/16)*sqrt(2)
    "C2": q15(0.92387953),   # cos(2pi/16)*sqrt(2)
    "C3": q15(0.83146961),   # cos(3pi/16)*sqrt(2)
    "C5": q15(0.55557023),   # cos(5pi/16)*sqrt(2)
    "C6": q15(0.38268343),   # cos(6pi/16)*sqrt(2)
    "C7": q15(0.19509032),   # cos(7pi/16)*sqrt(2)
}


# ============================================================================
#  canonical Huffman 码字生成 (T.81 Annex C)
# ============================================================================
def build_codes(bits, huffval, name):
    """bits: 长度 17 的列表, bits[i] = 码长 i 的码字个数 (bits[0] 忽略)
    huffval: 符号列表
    返回 {符号: (码字, 码长)}
    """
    code = 0
    k = 0
    table = {}
    total = 0
    for length in range(1, 17):
        n = bits[length]
        for _ in range(n):
            if k >= len(huffval):
                raise ValueError("%s: bits 与 huffval 数量不一致" % name)
            table[huffval[k]] = (code, length)
            k += 1
            code += 1
            total += 1
        code <<= 1
    if k != len(huffval):
        raise ValueError("%s: 只用了 %d 个符号, 但有 %d 个" % (name, k, len(huffval)))
    if len(bits) != 17:
        raise ValueError("%s: bits 应为 17 个元素, 实际 %d" % (name, len(bits)))

    # ---- 自校验 1: Kraft 不等式。合法前缀码必须 <= 1。
    #     注意: JPEG 规范给的这套标准表是**不完备**前缀码 (Kraft < 1),
    #     也就是码字空间没用满 —— 这是 T.81 的设计, 不是错误。
    kraft = sum(bits[l] * (2 ** (16 - l)) for l in range(1, 17))
    if kraft > (1 << 16):
        raise ValueError("%s: Kraft 和 = %d > %d (不是合法前缀码)"
                         % (name, kraft, 1 << 16))
    slack = (1 << 16) - kraft

    # ---- 自校验 2: 码字不能互为前缀 ----
    items = sorted(table.items(), key=lambda kv: (kv[1][1], kv[1][0]))
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            c1, l1 = items[i][1]
            c2, l2 = items[j][1]
            if l2 > l1 and (c2 >> (l2 - l1)) == c1:
                raise ValueError("%s: %02X 是 %02X 的前缀" % (name, items[i][0], items[j][0]))

    # ---- 自校验 3: 最大码长 <= 16 ----
    maxlen = max(l for _, l in table.values())
    print("  %-14s 符号 %3d 个, 最大码长 %2d, Kraft %d/%d%s"
          % (name, len(table), maxlen, kraft, 1 << 16,
             "  (不完备, 符合 T.81)" if slack else "  (完备)"))
    return table


# ============================================================================
#  生成 Verilog 头文件
# ============================================================================
def verilog_func(name, table, width_in=8, comment=""):
    """生成一个 "符号 -> {码长, 码字}" 的查表函数

    返回 21 位: [20:16] = 码长(1..16), [15:0] = 码字(左对齐前补零)
    """
    lines = []
    lines.append("// %s" % comment)
    lines.append("function [20:0] %s;" % name)
    lines.append("    input [%d:0] sym;" % (width_in - 1))
    lines.append("    begin")
    lines.append("        case (sym)")
    for sym in sorted(table.keys()):
        code, ln = table[sym]
        lines.append("            8'h%02X: %s = 21'h%05X;   // 码长%2d"
                     % (sym, name, (ln << 16) | code, ln))
    lines.append("            default: %s = 21'h00000;" % name)
    lines.append("        endcase")
    lines.append("    end")
    lines.append("endfunction")
    return "\n".join(lines)


def qtable_verilog(name, q, comment):
    lines = ["// %s" % comment]
    lines.append("function [7:0] %s;" % name)
    lines.append("    input [5:0] idx;")
    lines.append("    begin")
    lines.append("        case (idx)")
    for i, v in enumerate(q):
        lines.append("            6'd%-2d: %s = 8'd%3d;" % (i, name, v))
    lines.append("            default: %s = 8'd255;" % name)
    lines.append("        endcase")
    lines.append("    end")
    lines.append("endfunction")
    return "\n".join(lines)


def zigzag_verilog():
    lines = ["// zigzag 顺序: 索引 k -> 自然(行优先)系数下标"]
    lines.append("function [5:0] jpeg_zigzag;")
    lines.append("    input [5:0] k;")
    lines.append("    begin")
    lines.append("        case (k)")
    for i, v in enumerate(ZIGZAG):
        lines.append("            6'd%-2d: jpeg_zigzag = 6'd%-2d;" % (i, v))
    lines.append("            default: jpeg_zigzag = 6'd0;")
    lines.append("        endcase")
    lines.append("    end")
    lines.append("endfunction")
    return "\n".join(lines)


def main():
    print("=== 生成 JPEG 标准表 (T.81 Annex K) ===")

    tables = {
        "dc_lum": build_codes(DC_LUM_BITS, DC_LUM_VALS, "DC luminance"),
        "dc_chr": build_codes(DC_CHR_BITS, DC_CHR_VALS, "DC chrominance"),
        "ac_lum": build_codes(AC_LUM_BITS, AC_LUM_VALS, "AC luminance"),
        "ac_chr": build_codes(AC_CHR_BITS, AC_CHR_VALS, "AC chrominance"),
        "lossless": build_codes(LOSSLESS_BITS, LOSSLESS_VALS, "Lossless DC"),
    }

    # 交叉验证: 规范里给出的已知码字
    checks = [
        ("dc_lum", 0x00, (0b00, 2)),
        ("dc_lum", 0x0B, (0b111111110, 9)),
        ("dc_chr", 0x00, (0b00, 2)),
        ("ac_lum", 0x00, (0b1010, 4)),      # EOB
        ("ac_lum", 0xF0, (0b11111111001, 11)),  # ZRL
        ("ac_chr", 0x00, (0b00, 2)),
        ("lossless", 0x00, (0b00, 2)),
        ("lossless", 0x10, (0b11111111111110, 14)),
    ]
    print("\n=== 与规范已知码字交叉验证 ===")
    ok = True
    for tname, sym, expect in checks:
        got = tables[tname][sym]
        flag = "OK " if got == expect else "✗✗✗"
        if got != expect:
            ok = False
        print("  %s %-9s sym=0x%02X  期望=%s  实际=%s"
              % (flag, tname, sym, expect, got))
    if not ok:
        print("\n!! 码字与规范不符, 表定义可能有误, 已中止 !!")
        return 1

    # ---------- 写出 Verilog ----------
    os.makedirs(os.path.dirname(OUT_VH), exist_ok=True)
    parts = []
    parts.append("""//==============================================================================
//  jpeg_defs.vh
//  JPEG 标准表 —— **本文件由 tools/gen_jpeg_tables.py 自动生成, 请勿手改**
//
//  数据来源: ITU-T T.81 (JPEG) Annex K
//    K.1 量化表      -> jpeg_q_lum / jpeg_q_chr
//    K.3 DC 差分表   -> jpeg_huff_dc_lum / jpeg_huff_dc_chr
//    K.5 AC 系数表   -> jpeg_huff_ac_lum / jpeg_huff_ac_chr
//    H  无损 DC 表   -> jpeg_huff_lossless
//
//  霍夫曼查表函数返回 21 位: [20:16]=码长(1..16), [15:0]=码字(低位对齐)
//  生成时已做 Kraft 不等式与前缀性自校验, 并与规范给出的已知码字交叉比对。
//
//  ⚠ 本文件 **故意不加 include guard**:
//    里面是 localparam 和 function —— 每个 include 它的模块都需要一份自己的
//    副本。若加了 guard, 第二个模块就什么都拿不到了。
//    所以必须把 `include 放在 **module 内部**, 且每个模块都会展开一份。
//==============================================================================

//--------------------------------------------------------------- 图像参数
localparam JPEG_H_ACTIVE = 1920;    // 有效宽度
localparam JPEG_V_ACTIVE = 1080;    // 有效高度
localparam JPEG_MCU_W    = 16;      // MCU 宽 (4:2:2 = 2 个 Y 块)
localparam JPEG_MCU_H    = 8;       // MCU 高
localparam JPEG_MCU_X    = JPEG_H_ACTIVE / JPEG_MCU_W;   // 120
localparam JPEG_MCU_Y    = JPEG_V_ACTIVE / JPEG_MCU_H;   // 135
localparam JPEG_BLK_MIN  = 0;       // 系数最小 -1023 (10 位有符号)
localparam JPEG_BLK_MAX  = 1023;

//--------------------------------------------------------------- AAN 常数 (Q15)
localparam [15:0] AAN_ONE = 16'd32768;
""" + "\n".join("localparam [15:0] AAN_%s = 16'd%d;" % (k, v)
                for k, v in sorted(AAN_C.items())) + "\n")

    parts.append("\n//--------------------------------------------------------------- 量化表 (Annex K.1)")
    parts.append(qtable_verilog("jpeg_q_lum", Q_LUM, "亮度量化表基准值 (质量 50)"))
    parts.append("")
    parts.append(qtable_verilog("jpeg_q_chr", Q_CHR, "色度量化表基准值 (质量 50)"))

    parts.append("\n//--------------------------------------------------------------- zigzag")
    parts.append(zigzag_verilog())

    parts.append("\n//--------------------------------------------------------------- 霍夫曼表 (Annex K.3 / H)")
    parts.append(verilog_func("jpeg_huff_dc_lum", tables["dc_lum"], 8,
                              "DC 差分表 · 亮度 (Table K.3)"))
    parts.append("")
    parts.append(verilog_func("jpeg_huff_dc_chr", tables["dc_chr"], 8,
                              "DC 差分表 · 色度 (Table K.4)"))
    parts.append("")
    parts.append(verilog_func("jpeg_huff_ac_lum", tables["ac_lum"], 8,
                              "AC 系数表 · 亮度 (Table K.5), 符号 = (游程<<4)|分类"))
    parts.append("")
    parts.append(verilog_func("jpeg_huff_ac_chr", tables["ac_chr"], 8,
                              "AC 系数表 · 色度 (Table K.6)"))
    parts.append("")
    parts.append(verilog_func("jpeg_huff_lossless", tables["lossless"], 8,
                              "无损模式 DC 表 (Annex H Table K.3), 符号 = 幅度分类 0..16"))

    parts.append("""
//--------------------------------------------------------------- 工具函数
// 幅度分类: 求 |v| 的位宽, 即 JPEG 的 SSSS (0..15)
//   用 GCC 风格的分支树, 综合成 LUT 与优先级编码器
function [3:0] jpeg_ssss;
    input [15:0] mag;              // 传入 |v|
    begin
        if      (mag < 16'd1)     jpeg_ssss = 4'd0;
        else if (mag < 16'd2)     jpeg_ssss = 4'd1;
        else if (mag < 16'd4)     jpeg_ssss = 4'd2;
        else if (mag < 16'd8)     jpeg_ssss = 4'd3;
        else if (mag < 16'd16)    jpeg_ssss = 4'd4;
        else if (mag < 16'd32)    jpeg_ssss = 4'd5;
        else if (mag < 16'd64)    jpeg_ssss = 4'd6;
        else if (mag < 16'd128)   jpeg_ssss = 4'd7;
        else if (mag < 16'd256)   jpeg_ssss = 4'd8;
        else if (mag < 16'd512)   jpeg_ssss = 4'd9;
        else if (mag < 16'd1024)  jpeg_ssss = 4'd10;
        else if (mag < 16'd2048)  jpeg_ssss = 4'd11;
        else if (mag < 16'd4096)  jpeg_ssss = 4'd12;
        else if (mag < 16'd8192)  jpeg_ssss = 4'd13;
        else if (mag < 16'd16384) jpeg_ssss = 4'd14;
        else                      jpeg_ssss = 4'd15;
    end
endfunction
""")

    text = "\n".join(parts)
    with open(OUT_VH, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)

    print("\n=== 已写出 ===")
    print("  %s  (%d 字节, %d 行)" % (OUT_VH, len(text), text.count("\n") + 1))
    print("\nAAN Q15 常数: %s" % AAN_C)
    return 0


if __name__ == "__main__":
    sys.exit(main())
