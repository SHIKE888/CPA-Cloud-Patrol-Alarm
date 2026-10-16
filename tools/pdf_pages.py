#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 IMX415 数据手册的指定页渲染成 PNG, 便于直接看多列表格。

用法:
    python pdf_pages.py 48 49 54 57 59
输出到 docs/pdfpage/pNN.png
"""
import os
import sys

import pymupdf

PDF = (r"C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415\docs"
       r"\IMX415-AAQR-G_E_Datasheet_E19505D2X.pdf")
OUTDIR = (r"C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415\docs"
          r"\pdfpage")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    os.makedirs(OUTDIR, exist_ok=True)
    doc = pymupdf.open(PDF)
    for a in sys.argv[1:]:
        n = int(a)
        page = doc[n - 1]
        # 2 倍缩放, 保证表格小字也能看清
        pix = page.get_pixmap(matrix=pymupdf.Matrix(2.6, 2.6))
        out = os.path.join(OUTDIR, "p%02d.png" % n)
        pix.save(out)
        print("  p%-3d -> %s  (%d x %d)" % (n, out, pix.width, pix.height))


if __name__ == "__main__":
    main()
