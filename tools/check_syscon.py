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
RTL = os.path.join(ROOT, 'fpga', 'uisrc', '01_rtl')

SUITE = os.path.join(os.environ['USERPROFILE'], 'oss-cad-suite')

# 需要检查的例化: 模块名 -> 实例名
TARGETS = [
    ('preproc_top', 'u_preproc'),
    ('cfg_ctrl_top', 'u_cfg_ctrl'),
]

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


def main():
    with open(SYS_TOP, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()

    blocks = []
    print("=" * 70)
    print(" 集成预检: 抽取 system_top 里的例化原文单独编译")
    print("=" * 70)

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

    # 先把源文件路径解析出来 (既用于编译, 也用于解析端口位宽)
    srcs = ['preproc_top.v', 'preproc_win3x3.v', 'preproc_edge.v',
            'cfg_ctrl_top.v', 'i2c_slave.v', 'jpeg_regfile.v']
    paths = []
    for s in srcs:
        found = None
        for dirpath, _, files in os.walk(RTL):
            if s in files:
                found = os.path.join(dirpath, s)
                break
        if not found:
            print("  ✗ 找不到源文件 %s" % s)
            return 1
        paths.append(found)

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
