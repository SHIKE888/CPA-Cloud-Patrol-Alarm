#!/bin/sh
# 连续 20 帧一次性灌入, multipartmux 出文件, 逐段解码检查
PY=/opt/miniforge3/envs/mlk-ov/bin/python
pkill -f 'gst-launch-1.0 -q fdsrc' 2>/dev/null
sleep 1
rm -f /tmp/multi.mjpg
i=0
: > /tmp/in20.nv12
while [ $i -lt 20 ]; do
  cat /tmp/small.nv12 >> /tmp/in20.nv12
  i=$((i + 1))
done
ls -l /tmp/in20.nv12
cat /tmp/in20.nv12 | gst-launch-1.0 -q \
  fdsrc fd=0 blocksize=2519424 ! \
  rawvideoparse format=nv12 width=1728 height=972 ! \
  mppjpegenc ! multipartmux boundary=framebnd ! \
  filesink location=/tmp/multi.mjpg
ls -l /tmp/multi.mjpg
$PY - <<'PYEOF'
import numpy as np
import cv2

BND = b"--framebnd"
d = open("/tmp/multi.mjpg", "rb").read()
parts = d.split(BND)
print("段数(含尾部):", len(parts))
idx = 0
bad = 0
for p in parts:
    h = p.find(b"\r\n\r\n")
    if h < 0:
        continue
    head = p[:h].decode("latin1", "replace")
    ln = -1
    for line in head.split("\r\n"):
        if line.lower().startswith("content-length:"):
            ln = int(line.split(":", 1)[1])
    if ln < 0:
        continue
    jpg = p[h + 4:h + 4 + ln]
    img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_GRAYSCALE)
    if img is None:
        print("  #%02d %7dB 解码失败" % (idx, len(jpg)))
        bad += 1
    else:
        s = float(img.std())
        mark = "  <<< 灰" if s < 3 else ""
        if s < 3:
            bad += 1
        print("  #%02d %7dB %dx%d std=%.1f%s" % (idx, len(jpg), img.shape[1], img.shape[0], s, mark))
    idx += 1
print("总段 %d, 坏 %d" % (idx, bad))
PYEOF
