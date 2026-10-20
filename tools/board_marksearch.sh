#!/bin/sh
# 在整帧 Y 平面里搜索帧标记 A5 5A，确认 FPGA 到底写没写、写在哪。
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
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
print("negotiated %dx%d" % (w, h))

ok, f = cap.read()
if not ok:
    print("read fail"); sys.exit(1)
cap.release()

b = f.reshape(-1).astype(np.uint8)
wh = w * h
y = b[:wh]
uv = b[wh:wh * 2] if b.size >= wh * 2 else b[wh:]

print("Y[0:48]   =", ' '.join('%02X' % v for v in y[:48]))
print("UV[0:48]  =", ' '.join('%02X' % v for v in uv[:48]))

# 1) 整帧搜 A5 5A
a5 = np.where(y[:-1] == 0xA5)[0]
hits = []
for i in a5:
    if y[i + 1] == 0x5A:
        hits.append(int(i))
print("整帧 A5 5A 命中 %d 处" % len(hits))
for i in hits[:10]:
    row, col = divmod(i, w)
    tail = ' '.join('%02X' % v for v in y[i:i + 8])
    print("   idx=%-8d row=%-4d col=%-4d bytes=%s" % (i, row, col, tail))

# 2) 单独看两个 magic 字节出现在哪
for pat, name in ((0xA5, 'A5'), (0x5A, '5A'), (0xFF, 'FF')):
    idx = np.where(y[:4096] == pat)[0]
    print("%s 在前 4096 像素里出现 %d 次: %s" %
          (name, len(idx), [int(v) for v in idx[:12]]))

# 3) UV 平面的 0x80 中性点（标记会把 Cb/Cr 写成 0x80）
z = np.where(uv[:512] == 0x80)[0]
print("UV 前 512 字节里 0x80 出现 %d 次: %s" %
      (len(z), [int(v) for v in z[:16]]))
PY
