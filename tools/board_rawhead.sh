#!/bin/sh
# 抓一帧原始 NV16，打印头 32 字节 + 前两行像素，用来确认 FPGA 的帧标记有没有到。
PY=/opt/miniforge3/envs/mlk-ov/bin/python
[ -x "$PY" ] || PY=python3
$PY - <<'PY'
import sys
try:
    import cv2, numpy as np
except Exception as e:
    print("no cv2: %s" % e); sys.exit(1)

cap = cv2.VideoCapture('/dev/video22', cv2.CAP_V4L2)
cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
if not cap.isOpened():
    print("open failed"); sys.exit(1)

w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
print("negotiated %dx%d" % (w, h))

got = 0
for i in range(8):
    ok, f = cap.read()
    if not ok or f is None:
        print("  read %d: fail" % i); continue
    b = f.reshape(-1)
    if b.size < 64:
        print("  read %d: weird size %d shape %s" % (i, b.size, f.shape)); continue
    head = ' '.join('%02X' % int(x) for x in b[:32])
    print("  read %d: size=%d shape=%s" % (i, b.size, f.shape))
    print("           head32 = %s" % head)
    wh = w * h
    if b.size >= wh:
        y = b[:wh].reshape(h, w)
        print("           Y[0,0:16] = %s" % list(y[0, 0:16]))
        print("           Y mean=%.1f min=%d max=%d" % (y.mean(), y.min(), y.max()))
    got += 1
    if got >= 3:
        break
cap.release()
print("done, frames=%d" % got)
PY
