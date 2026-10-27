#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""停服务后直接测 capture fps (照抄 mipi_webstream 的打开顺序)。"""
import subprocess
import time

import cv2
import numpy as np

DEV = "/dev/video22"


def sh(c):
    try:
        return subprocess.run(c, shell=True, capture_output=True,
                              text=True, timeout=20).stdout.strip()
    except Exception as e:                                         # noqa: BLE001
        return "ERR %s" % e


print("set-fmt:", sh("v4l2-ctl -d %s --set-fmt-video=width=1920,height=1080,"
                     "pixelformat=NV16" % DEV))

cap = cv2.VideoCapture(DEV, cv2.CAP_V4L2)
cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"NV16"))
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
cap.set(cv2.CAP_PROP_BUFFERSIZE, 4)
cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
print("opened:", cap.isOpened())

N = 120
ts = []
bad = 0
shape = None
first = None
t0 = time.time()
while len(ts) < N and time.time() - t0 < 20:
    ok, f = cap.read()
    if not ok or f is None:
        bad += 1
        continue
    ts.append(time.perf_counter())
    if shape is None:
        shape = f.shape
        first = bytes(f.reshape(-1)[:8]).hex()
cap.release()

if len(ts) > 5:
    d = np.diff(np.array(ts)) * 1e3
    print("frames %d  shape %s  首 8 字节 %s" % (len(ts), shape, first))
    print("间隔 中位 %.2fms  min %.2f  max %.2f  => %.1f fps"
          % (np.median(d), d.min(), d.max(), 1000.0 / np.median(d)))
    print("长间隔(>1.5x中位) = %d   读失败 = %d" % ((d > 1.5 * np.median(d)).sum(), bad))
else:
    print("帧太少:", len(ts), "read 失败", bad)
