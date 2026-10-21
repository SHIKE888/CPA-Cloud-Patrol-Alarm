#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cmp_jpeg.py —— 比较 RTL 仿真输出与 Python 参考

用法:
    python tools/cmp_jpeg.py [rtl.jpg] [ref.jpg]
默认路径是 fpga/sim/rtl.jpg 与 fpga/sim/ref.jpg

退出码 0 = 完全一致, 1 = 有差异。
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.normpath(os.path.join(HERE, "..", "fpga", "sim"))


def main():
    a_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SIM, "rtl.jpg")
    b_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(SIM, "ref.jpg")

    with open(a_path, "rb") as f:
        a = f.read()
    with open(b_path, "rb") as f:
        b = f.read()

    if a == b:
        print("IDENTICAL %d bytes  md5=%s" % (len(a), hashlib.md5(a).hexdigest()))
        return 0

    n = min(len(a), len(b))
    diffs = [i for i in range(n) if a[i] != b[i]]
    print("DIFF rtl=%d ref=%d  mismatches=%d  first=%s"
          % (len(a), len(b), len(diffs), diffs[0] if diffs else "-"))
    if diffs:
        d = diffs[0]
        print("  rtl %s" % a[max(0, d - 8):d + 12].hex(" "))
        print("  ref %s" % b[max(0, d - 8):d + 12].hex(" "))
    return 1


if __name__ == "__main__":
    sys.exit(main())
