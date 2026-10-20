#!/usr/bin/env python3
"""抓 9012 的 snapshot.jpg 并打印统计量。用法: _snap_stat.py [out.jpg]"""
import sys
import urllib.request
import numpy as np
import cv2

out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/snap.jpg"
url = "http://127.0.0.1:9012/snapshot.jpg"
d = urllib.request.urlopen(url, timeout=20).read()
open(out, "wb").write(d)
im = cv2.imread(out)
print("bytes", len(d), "path", out)
if im is None:
    print("imread failed")
    sys.exit(1)
print("shape", im.shape)
print("mean  %.2f" % im.mean())
print("std   %.2f" % im.std())
g = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY)
print("gray mean %.2f std %.2f min %d max %d"
      % (g.mean(), g.std(), g.min(), g.max()))
# 一行/一列的亮度，用来看有没有行错位造成的规律性条带
rowm = g.mean(axis=1)
colm = g.mean(axis=0)
print("row-mean  : first 12 =", np.round(rowm[:12], 1).tolist())
print("col-mean  : first 12 =", np.round(colm[:12], 1).tolist())
# 相邻行差分的标准差：正常画面很小，条纹/撕裂会很大
drow = np.abs(np.diff(rowm))
print("adjacent-row |diff| mean %.3f max %.2f" % (drow.mean(), drow.max()))
