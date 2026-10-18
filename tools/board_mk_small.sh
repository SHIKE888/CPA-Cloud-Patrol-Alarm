#!/bin/sh
pkill -f '[m]pptest.py'
pkill -f '[g]st-launch-1.0 -q fdsrc'
sleep 1
/opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import numpy as np
import cv2

FS = 3840 * 2160 * 2
W, H = 3840, 2160
TW, TH = 1728, 972
d = np.fromfile("/tmp/seq.nv16", np.uint8)
n = len(d) // FS
out = []
for i in range(min(n, 4)):
    f = d[i * FS:(i + 1) * FS]
    y = f[:W * H].reshape(H, W)
    uv = f[W * H:].reshape(H, W // 2, 2)
    ys = cv2.resize(y, (TW, TH), interpolation=cv2.INTER_LINEAR)
    # NV16: UV 平面高度不变(每像素一个 UV 对, 水平半分辨率)
    us = cv2.resize(uv[:, :, 0], (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
    vs = cv2.resize(uv[:, :, 1], (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
    uvs = np.stack([us, vs], axis=2).reshape(-1)
    out.append(np.concatenate([ys.reshape(-1), uvs]))
arr = np.concatenate(out).astype(np.uint8)
arr.tofile("/tmp/small.nv16")
print("写出 /tmp/small.nv16  %d 帧 %dx%d  单帧 %d B" % (len(out), TW, TH, TW * TH * 2))
PY
