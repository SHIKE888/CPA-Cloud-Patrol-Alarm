#!/usr/bin/env python3
"""连抓两张 snapshot.jpg 做差分，判断画面是活的还是冻结的。
用法: _snap_live.py [间隔秒]"""
import sys
import time
import urllib.request
import numpy as np
import cv2

gap = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
url = "http://127.0.0.1:9012/snapshot.jpg"


def grab():
    d = urllib.request.urlopen(url, timeout=20).read()
    a = np.frombuffer(d, dtype=np.uint8)
    return cv2.imdecode(a, cv2.IMREAD_COLOR)


a = grab()
time.sleep(gap)
b = grab()
if a is None or b is None:
    print("decode failed")
    sys.exit(1)
d = cv2.absdiff(a, b)
g = cv2.cvtColor(d, cv2.COLOR_BGR2GRAY)
print("shot1 mean %.2f  shot2 mean %.2f" % (a.mean(), b.mean()))
print("absdiff: mean %.3f  max %d  pixels>8 = %.2f%%"
      % (g.mean(), g.max(), 100.0 * (g > 8).mean()))
if g.mean() < 0.05 and g.max() < 3:
    print("=> 两张几乎完全一样：画面可能是冻结的")
else:
    print("=> 有变化：画面是活的")
