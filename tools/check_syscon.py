#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_syscon.py —— 集成预检: 把 system_top.v 里的例化原文抠出来单独编译

目的: TD 编译一次要 10 分钟, 而 system_top 里包含加密 IP (.enc.v) 无法在本机
      完整展开。本脚本只抽出我们新加的那几个例化块, 配真实模块源码编译,
      用来抓「端口名拼错 / 位宽不匹配 / 忘了连某个端口」这类低级错误。

用法: python tools/check_syscon.py
"""
import os
import re
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SYS_TOP = os.path.join(ROOT, 'fpga', 'uisrc', '01_rtl', 'system_top.v')
# 搜整个 uisrc: 新模块在 01_rtl 下, 而 ui_cfg_imx415 那些在 03_ip 下
RTL = os.path.join(ROOT, 'fpga', 'uisrc')

SUITE = os.path.join(os.environ['USERPROFILE'], 'oss-cad-suite')

# 需要检查的例化: 模块名 -> 实例名
#
# ⚠ 不要把厂商 IP (ui_cfg_imx415 / ui_isp_top 这些) 放进来: 它们的代码风格
#   不被 iverilog 接受 —— ui_cfg_imx415.v 里 iic_busy 是隐式声明 (用在声明之前),
#   而且 ui_imx415reg 的 REG_INDEX/REG_DATA 端口是 9/32 位、实际连的是 8/24 位。
#   TD 容忍这些, iverilog 直接报错, 加了反而把真正的报错淹没掉。
#   这类厂商 IP 的端口改动只能人工核对。
TARGETS = [
    ('preproc_top', 'u_preproc'),
    ('preproc_post', 'u_preproc_post'),
    ('cam_param', 'u_cam_param'),
    ('cfg_ctrl_top', 'u_cfg_ctrl'),
]

# 新增的 RTL 源文件 (浅层文件名, 脚本会递归找)
SRC_NAMES = ['preproc_top.v', 'preproc_win3x3.v', 'preproc_edge.v',
             'preproc_post.v', 'cfg_ctrl_top.v', 'i2c_slave.v',
             'jpeg_regfile.v', 'cam_param.v']

# 这些是 system_top 里的 localparam, 检查模块里要补上
EXTRA_DECL = """
	localparam integer H_ACTIVE   = 1920;
	localparam integer V_ACTIVE   = 1080;
	localparam integer W_BEATS_PER_LINE = H_ACTIVE / 4;
	localparam integer R_BEATS_PER_LINE = H_ACTIVE / 2;
"""


def extract_inst(text, mod, inst):
    """从 text 中抽出 "<mod> #( ... ) <inst> ( ... );" 整块"""
    pat = re.compile(re.escape(mod) + r'\s*#?\s*\(', re.M)
    m = pat.search(text)
    if not m:
        return None, "找不到模块例化 %s" % mod
    start = m.start()
    # 从 start 往后找 "<inst> (" 再匹配到配对的 ");"
    mi = re.compile(r'\b' + re.escape(inst) + r'\s*\(').search(text, m.end())
    if not mi:
        return None, "找不到实例名 %s" % inst
    i = mi.end()
    depth = 1
    while i < len(text) and depth:
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
        i += 1
    # 吃掉后面的分号
    j = i
    while j < len(text) and text[j] in ' \t\r\n':
        j += 1
    if j < len(text) and text[j] == ';':
        j += 1
    return text[start:j], None


def parse_port_widths(path):
    """从模块源码的端口声明解析 {信号名: 位宽}

    行首(允许缩进)的 input/output/inout 声明。位宽写成 [msb:lsb]。
    这样生成检查模块时用**正确位宽**声明, 剩下的位宽警告就是真实错配。
    """
    widths = {}
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            m = re.match(r'\s*(input|output|inout)\s+(?:wire|reg|logic)?\s*'
                         r'(\[[^\]]+\])?\s*([A-Za-z_]\w*)\s*(?:,|;|\)|$)',
                         line)
            if not m:
                continue
            name, rng = m.group(3), m.group(2)
            w = 1
            if rng:
                try:
                    a, b = rng.strip('[]').split(':')
                    w = abs(int(a) - int(b)) + 1
                except Exception:
                    w = 1
            widths[name] = max(widths.get(name, 0), w)
    return widths


def collect_signals(block):
    """从例化块里收集被连接的网络名 (形如 .port(sig) ), 用于生成声明"""
    sigs = set()
    for m in re.finditer(r'\.\s*\w+\s*\(\s*([^)]*?)\s*\)', block):
        s = m.group(1).strip()
        if not s or re.fullmatch(r"[0-9']+[bdhoBDHO]?[0-9a-fA-F_xzXZ]*", s):
            continue
        # 只取简单标识符 (丢掉表达式)
        if re.fullmatch(r'[A-Za-z_]\w*', s):
            sigs.add(s)
    return sigs


def collect_port_pairs(block):
    """收集例化块里的 (.端口(信号)) 对

    ⚠ 关键: 位宽是以**端口**定义的, 但我们声明的是**被连接的信号**。
      必须把 port->width 映射成 signal->width, 否则位宽检查形同虚设。
    """
    pairs = []
    for m in re.finditer(r'\.\s*(\w+)\s*\(\s*([^)]*?)\s*\)', block):
        port, s = m.group(1), m.group(2).strip()
        if re.fullmatch(r'[A-Za-z_]\w*', s):
            pairs.append((port, s))
    return pairs


# ==============================================================================
#  静态检查 (纯文本分析, 必须跑在**真实文件**上)
#
#  ⚠ 教训 (2026-10-15): 本脚本原先只把例化块抠出来、自己补上 wire 声明去编译,
#    结果永远看不到「信号使用早于声明」。实际那次 TD 编译报了 4 条 HDL-7225,
#    .i_data(S_pp_tdata) 在 322 行用, wire [127:0] S_pp_tdata 在 484 行才声明,
#    于是 128 bit 数据线被隐式推断成 1 bit。工具骗了自己一次, 不要再骗第二次。
# ==============================================================================
VERILOG_KW = {
    'module', 'endmodule', 'input', 'output', 'inout', 'wire', 'reg', 'logic',
    'assign', 'always', 'begin', 'end', 'if', 'else', 'case', 'casex', 'casez',
    'endcase', 'posedge', 'negedge', 'or', 'and', 'not', 'parameter',
    'localparam', 'integer', 'genvar', 'generate', 'endgenerate', 'for',
    'default', 'signed', 'unsigned', 'initial', 'function', 'endfunction',
    'task', 'endtask', 'while', 'repeat', 'forever', 'defparam',
}

_DECL_KW = ('input', 'output', 'inout', 'wire', 'reg', 'logic')
DECL_LINE_RE = re.compile(r'^\s*(?:' + '|'.join(_DECL_KW) + r')\b')
_RE_BEGIN = re.compile(r'begin\b')
_RE_END = re.compile(r'end\b')


def read_text(path):
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        return f.read()


def strip_comments_line(line):
    line = re.sub(r'//.*$', '', line)
    line = re.sub(r'/\*.*?\*/', ' ', line)
    return line


def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)
    return re.sub(r'//[^\n]*', '', src)


def strip_comments_keeplines(src):
    """去注释但**保留换行** —— 行号仍然对得上, 才能准确报行号。

    ⚠ 块注释 /* ... */ 经常跨行。只按行去注释会漏掉跨行块的中间行,
      把注释里的文字当成代码 —— 曾因此把注释里的 I_dsi_en 误报成
      “使用早于声明”。
    """
    def _blank(m):
        return re.sub(r'[^\n]', ' ', m.group(0))
    src = re.sub(r'/\*.*?\*/', _blank, src, flags=re.S)
    return re.sub(r'//[^\n]*', '', src)


def parse_decl_names(line):
    """从一行声明里取出被声明的信号名。

    处理: 'wire [31:0] a, b;' / 'input wire [127:0] x' / 'output reg [7:0] y,'
    """
    s = strip_comments_line(line)
    s = re.sub(r'\[[^\]]*\]', ' ', s)                 # 去位宽
    s = s.split('=')[0]                               # 去初始化值
    s = re.sub(r'^\s*[A-Za-z_]\w*', ' ', s, count=1)  # 去首个关键字
    names = []
    for tok in s.split(','):
        m = re.search(r'([A-Za-z_]\w*)\s*[;)]?\s*$', tok.strip())
        if m and m.group(1).lower() not in VERILOG_KW:
            names.append(m.group(1))
    return names


def check_decl_order(path):
    """检测「信号在声明之前被使用」—— TD 报 HDL-7225 already implicitly declared。

    Verilog 里未声明的标识符会被隐式推断成 1 bit wire, 所以:
        rgb_to_yuv422_quad u_x ( .i_data (S_pp_tdata) );   // 322 行
        wire [127:0] S_pp_tdata;                           // 484 行
    会让 128 bit 数据线塌成 1 bit。本函数把这类问题抓出来。
    """
    fn = os.path.basename(path)
    first_decl, first_use = {}, {}
    src = strip_comments_keeplines(read_text(path))
    for i, raw in enumerate(src.splitlines(), 1):
        if DECL_LINE_RE.match(raw):
            for n in parse_decl_names(raw):
                first_decl.setdefault(n, i)
        else:
            for m in re.finditer(r'[A-Za-z_]\w*', raw):
                n = m.group(0)
                if n.lower() not in VERILOG_KW:
                    first_use.setdefault(n, i)

    bad = [(n, u, first_decl[n]) for n, u in first_use.items()
           if n in first_decl and u < first_decl[n]]
    if not bad:
        return 0

    print("  ✗ [声明顺序] %s: %d 个信号在声明前被使用" % (fn, len(bad)))
    for n, u, d in sorted(bad, key=lambda t: t[1]):
        print("      %-20s 第 %d 行使用, 第 %d 行才声明" % (n, u, d))
    print("      -> 会被隐式声明成 1 bit wire, 多 bit 总线会塌掉")
    return len(bad)


def split_always_blocks(src):
    """把源码切成各个 always 块的文本 (按 begin/end 配对)

    ⚠ 必须先跳过敏感列表 @(...)。否则 `always @(posedge clk ...) begin`
      会被当成"无 begin 的单语句 always", 一路 find(';') 切到块内第一个分号,
      整块切碎 —— 多驱动检查就完全失效了 (曾因此漏掉 r_heartbeat)。
    """
    out = []
    for m in re.finditer(r'\balways\b', src):
        i = m.end()
        while i < len(src) and src[i] in ' \t\r\n':
            i += 1
        # 跳过 @(...) 敏感列表
        if src.startswith('@', i):
            i += 1
            while i < len(src) and src[i] in ' \t\r\n':
                i += 1
            if src[i:i + 1] == '(':
                depth = 0
                while i < len(src):
                    if src[i] == '(':
                        depth += 1
                    elif src[i] == ')':
                        depth -= 1
                        if depth == 0:
                            i += 1
                            break
                    i += 1
            while i < len(src) and src[i] in ' \t\r\n':
                i += 1
        if _RE_BEGIN.match(src, i):
            depth, j = 0, i
            while j < len(src):
                if _RE_BEGIN.match(src, j):
                    depth += 1
                    j += 5
                elif _RE_END.match(src, j):
                    depth -= 1
                    j += 3
                    if depth == 0:
                        break
                else:
                    j += 1
            out.append(src[i:j])
        else:
            j = src.find(';', i)
            if j > 0:
                out.append(src[i:j + 1])
    return out


def check_multi_driver(path):
    """检测同一寄存器在**多个 always 块**里被赋值

    TD 报: HDL-8007 net 'X' is constantly driven from multiple places。
    只统计确实是 reg 的信号, 免除 'if (a <= b)' 这类比较的误报。
    """
    src = strip_comments(read_text(path))
    block_text = split_always_blocks(src)
    if len(block_text) < 2:
        return 0

    regs = set()
    for line in src.splitlines():
        if DECL_LINE_RE.match(line) and re.search(r'\breg\b', line):
            regs.update(parse_decl_names(line))

    drv = {}
    for bi, blk in enumerate(block_text):
        for m in re.finditer(r'([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*<=', blk):
            if m.group(1) in regs:
                drv.setdefault(m.group(1), set()).add(bi)

    bad = {n: bs for n, bs in drv.items() if len(bs) > 1}
    if not bad:
        return 0

    print("  ✗ [多驱动] %s: %d 个寄存器在多个 always 块里赋值"
          % (os.path.basename(path), len(bad)))
    for n, bs in sorted(bad.items()):
        print("      %-20s 出现在块 #%s"
              % (n, ', '.join(str(b) for b in sorted(bs))))
    print("      -> TD HDL-8007 constantly driven from multiple places")
    return len(bad)


def main():
    with open(SYS_TOP, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()

    blocks = []
    print("=" * 70)
    print(" 集成预检: 抽取 system_top 里的例化原文单独编译")
    print("=" * 70)

    # 先把源文件路径解析出来 (既用于编译, 也用于解析端口位宽 / 静态检查)
    paths = []
    for s in SRC_NAMES:
        found = None
        for dirpath, _, files in os.walk(RTL):
            if s in files:
                found = os.path.join(dirpath, s)
                break
        if not found:
            print("  ✗ 找不到源文件 %s" % s)
            return 1
        paths.append(found)

    # ---------------- 静态检查 (必须在真实文件上做) ----------------
    print("\n[静态检查]")
    nerr = check_decl_order(SYS_TOP)
    for p in [SYS_TOP] + paths:
        nerr += check_multi_driver(p)
    if nerr:
        print("\n" + "=" * 70)
        print(" ✗ 静态检查不通过 (%d 处), 修完再编译" % nerr)
        print("=" * 70)
        return 1
    print("  ✓ 声明顺序 / 多驱动 均正常")

    for mod, inst in TARGETS:
        blk, err = extract_inst(text, mod, inst)
        if err:
            print("  ✗ %s" % err)
            return 1
        blocks.append(blk)
        print("\n[%s] 抽到 %d 行" % (inst, blk.count('\n') + 1))

    # 生成检查模块
    decls = EXTRA_DECL
    sigs = set()
    for b in blocks:
        sigs |= collect_signals(b)
    sigs = {s for s in sigs if s not in ('H_ACTIVE', 'V_ACTIVE')}

    # 汇总端口位宽
    width = {}
    for p in paths:
        for k, v in parse_port_widths(p).items():
            width[k] = max(width.get(k, 0), v)

    # 端口位宽 -> 被连接信号位宽
    sigw = {}
    for b in blocks:
        for port, sig in collect_port_pairs(b):
            sigw[sig] = max(sigw.get(sig, 1), width.get(port, 1))

    nwid = 0
    for s in sorted(sigs):
        w = sigw.get(s, 1)
        if w > 1:
            decls += "\twire [%d:0] %s;\n" % (w - 1, s)
            nwid += 1
        else:
            decls += "\twire %s;\n" % s
    print("\n  信号声明: %d 个 (其中 %d 个多位)" % (len(sigs), nwid))

    tb = "`timescale 1ns/1ps\n"
    tb += "module syscon_check;\n"
    tb += decls
    tb += "\n"
    for b in blocks:
        tb += b + "\n\n"
    tb += "endmodule\n"

    out_v = os.path.join(os.environ['TEMP'], 'syscon_check.v')
    with open(out_v, 'w', encoding='utf-8', newline='\n') as f:
        f.write(tb)
    print("\n  生成 %s (%d 行)" % (out_v, tb.count('\n') + 1))

    print("\n  源文件:")
    for p in paths:
        print("    %s" % p.replace(ROOT + os.sep, ''))

    # 编译 (只做 elaboration, 不跑仿真)
    # ⚠ Windows 上必须用**绝对路径**: CreateProcess 查可执行文件用的是
    #   调用进程的 PATH, 而不是我们传进去的 env['PATH']。
    iv = os.path.join(SUITE, 'bin', 'iverilog.exe')
    if not os.path.exists(iv):
        iv = 'iverilog'
    cmd = [iv, '-g2005', '-s', 'syscon_check',
           '-o', os.path.join(os.environ['TEMP'], 'syscon_check.vvp'),
           out_v] + paths

    env = dict(os.environ)
    # ⚠ oss-cad-suite 的 bin 和 lib **都要**加到 PATH: 可执行在 bin, DLL 在 lib。
    #   只加 bin 会得到 0xC0000139 (STATUS_ENTRYPOINT_NOT_FOUND)。
    env['PATH'] = (os.path.join(SUITE, 'bin') + os.pathsep +
                   os.path.join(SUITE, 'lib') + os.pathsep +
                   env.get('PATH', ''))
    env['YOSYSHQ_ROOT'] = SUITE
    print("\n  执行: %s -g2005 -s syscon_check ..." % os.path.basename(iv))
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.stdout.strip():
        print("  --- stdout ---")
        print(r.stdout)
    if r.stderr.strip():
        print("  --- stderr ---")
        print(r.stderr)

    print("=" * 70)
    if r.returncode == 0:
        print(" ✓ 预检通过: 例化端口名/位宽都能对上, 可以编译")
        print("=" * 70)
        return 0
    print(" ✗ 预检失败 (退出码 %d), 先修再编译" % r.returncode)
    print("=" * 70)
    return 1


if __name__ == '__main__':
    sys.exit(main())
