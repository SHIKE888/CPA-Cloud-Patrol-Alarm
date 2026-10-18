#!/bin/sh
# 生成 1728x972 的 NV12 与 NV16 测试数据(同一批真实帧)
PY=/opt/miniforge3/envs/mlk-ov/bin/python
$PY - <<'PYEOF'
import numpy as np
import cv2

FS = 3840 * 2160 * 2
W, H = 3840, 2160
TW, TH = 1728, 972
d = np.fromfile("/tmp/seq.nv16", np.uint8)
n = len(d) // FS
o16, o12 = [], []
for i in range(min(n, 4)):
    f = d[i * FS:(i + 1) * FS]
    y = f[:W * H].reshape(H, W)
    uv = f[W * H:].reshape(H, W // 2, 2)
    ys = cv2.resize(y, (TW, TH), interpolation=cv2.INTER_LINEAR)
    us = cv2.resize(uv[:, :, 0], (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
    vs = cv2.resize(uv[:, :, 1], (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
    uvs = np.stack([us, vs], axis=2).reshape(-1)
    o16.append(np.concatenate([ys.reshape(-1), uvs]))
    # NV12: UV 只要半高
    o12.append(np.concatenate([ys.reshape(-1),
                               uvs.reshape(TH, TW // 2, 2)[::2].reshape(-1)]))
np.concatenate(o16).astype(np.uint8).tofile("/tmp/small.nv16")
np.concatenate(o12).astype(np.uint8).tofile("/tmp/small.nv12")
print("NV16 帧 %d 字节/帧, NV12 帧 %d 字节/帧" %
      (TW * TH * 2, TW * TH * 3 // 2))
PYEOF
ls -l /tmp/small.nv16 /tmp/small.nv12
