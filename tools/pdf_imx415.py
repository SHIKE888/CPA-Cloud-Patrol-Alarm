#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 IMX415 数据手册里抽取关键内容。

用法:
    python pdf_imx415.py dump            # 全部文本 -> docs/IMX415_datasheet.txt
    python pdf_imx415.py find <关键字>   # 打印含关键字的页 + 前后文
"""
import os
import sys

import pymupdf

PDF = (r"C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415\docs"
       r"\IMX415-AAQR-G_E_Datasheet_E19505D2X.pdf")
OUT = (r"C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415\docs"
       r"\IMX415_datasheet.txt")


def pages():
    doc = pymupdf.open(PDF)
    for i, p in enumerate(doc):
        yield i + 1, p.get_text()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == "dump":
        with open(OUT, "w", encoding="utf-8") as f:
            for n, t in pages():
                f.write("\n===== PAGE %d =====\n" % n)
                f.write(t)
        print("已写出 %s  (%d 字节)" % (OUT, os.path.getsize(OUT)))
        return
    if cmd == "find":
        kw = sys.argv[2]
        ctx = int(sys.argv[3]) if len(sys.argv) > 3 else 300
        hits = 0
        for n, t in pages():
            lo = t.lower()
            k = kw.lower()
            pos = 0
            while True:
                i = lo.find(k, pos)
                if i < 0:
                    break
                hits += 1
                print("\n===== PAGE %d  @%d =====" % (n, i))
                print(t[max(0, i - ctx):i + ctx].replace("\n", " | "))
                pos = i + 1
                if hits > 40:
                    return
        if hits == 0:
            print("没找到 %r" % kw)
        return
    print("未知命令", cmd)


if __name__ == "__main__":
    main()
