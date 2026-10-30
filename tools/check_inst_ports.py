#!/usr/bin/env python3
"""check_inst_ports.py —— 静态比对"例化端口"与"模块端口"，防 HDL-8007

TD 报
    HDL-8007: cannot find port 'xxx' on this module in system_top.v(2389)
时，说明例化里传了模块没有的端口（或拼错名字）。这个脚本在综合前就能查出来。

用法:
    python check_inst_ports.py <父文件> <子模块名> <子模块文件>
例:
    python check_inst_ports.py fpga/uisrc/01_rtl/system_top.v \
           cfg_ctrl_top fpga/uisrc/01_rtl/ctrl/cfg_ctrl_top.v

退出码: 0 = 全部匹配; 1 = 有不匹配或缺端口
"""
import re
import sys


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//[^\n]*", "", s)
    return s


def module_ports(src, mod):
    """返回 (inputs, outputs, inouts) 三个集合。"""
    m = re.search(r"\bmodule\s+%s\b" % re.escape(mod), src)
    if not m:
        raise SystemExit("找不到 module %s" % mod)
    i = m.end()
    # 先跳过可能存在的参数列表 #( ... )
    while i < len(src) and src[i] in " \t\r\n":
        i += 1
    if i < len(src) and src[i] == "#":
        i += 1
        while i < len(src) and src[i] in " \t\r\n":
            i += 1
        depth = 0
        while i < len(src):
            if src[i] == "(":
                depth += 1
            elif src[i] == ")":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
    # 再找端口列表的 '('
    while i < len(src) and src[i] != "(":
        i += 1
    depth, j = 0, i
    while j < len(src):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    ports = src[i + 1:j]
    ins, outs, ios = set(), set(), set()
    for kw, bucket in (("input", ins), ("output", outs), ("inout", ios)):
        for mm in re.finditer(r"\b%s\b([^;)]*)" % kw, ports):
            seg = mm.group(1)
            # 去掉位宽 [..] 和 wire/reg/signed 等
            seg = re.sub(r"\[[^\]]*\]", " ", seg)
            seg = re.sub(r"\b(wire|reg|logic|signed|unsigned)\b", " ", seg)
            for name in re.findall(r"[A-Za-z_]\w*", seg):
                bucket.add(name)
    return ins, outs, ios


def inst_conns(src, mod):
    """返回该模块所有例化里用到的端口名集合（含多份例化的并集）。"""
    names = set()
    for m in re.finditer(r"\b%s\b\s*(#\s*\([^;]*?\)\s*)?(\w+)\s*\(" % re.escape(mod), src):
        start = m.end() - 1
        depth, j = 0, start
        while j < len(src):
            if src[j] == "(":
                depth += 1
            elif src[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = src[start + 1:j]
        for mm in re.finditer(r"\.(\w+)\s*\(", body):
            names.add(mm.group(1))
    return names


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    parent_f, mod, child_f = sys.argv[1], sys.argv[2], sys.argv[3]
    psrc = strip_comments(open(parent_f, encoding="utf-8", errors="replace").read())
    csrc = strip_comments(open(child_f, encoding="utf-8", errors="replace").read())
    ins, outs, ios = module_ports(csrc, mod)
    allp = ins | outs | ios
    conns = inst_conns(psrc, mod)
    if not conns:
        raise SystemExit("在 %s 里没找到 %s 的例化" % (parent_f, mod))

    bad = sorted(conns - allp)
    miss = sorted(allp - conns)
    print("module %s: input=%d output=%d inout=%d" % (mod, len(ins), len(outs), len(ios)))
    print("例化用到 %d 个端口名" % len(conns))
    if bad:
        print("!! 例化里出现了模块没有的端口（TD 会报 HDL-8007）:")
        for b in bad:
            print("     .%s(...)" % b)
    # 未连接的输出/输入是"可选"的，只提示
    if miss:
        print("   （未连接，通常无害）: %s" % ", ".join(miss))
    print("RESULT: %s" % ("FAIL" if bad else "PASS"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
