#!/bin/sh
# 最小复现: 只编 1 帧到文件, 排除管道/解析/时序全部干扰
PY=/opt/miniforge3/envs/mlk-ov/bin/python
pkill -f 'gst-launch-1.0 -q fdsrc' 2>/dev/null
sleep 1
cat /dev/null
for MODE in plain caps; do
  rm -f /tmp/one.jpg
  if [ "$MODE" = "plain" ]; then
    head -c 2519424 /tmp/small.nv12 | gst-launch-1.0 -q \
      fdsrc fd=0 blocksize=2519424 ! \
      rawvideoparse format=nv12 width=1728 height=972 ! \
      mppjpegenc ! filesink location=/tmp/one.jpg
  else
    head -c 2519424 /tmp/small.nv12 | gst-launch-1.0 -q \
      fdsrc fd=0 blocksize=2519424 ! \
      rawvideoparse format=nv12 width=1728 height=972 framerate=25/1 ! \
      video/x-raw,format=NV12,width=1728,height=972,framerate=25/1 ! \
      mppjpegenc ! filesink location=/tmp/one.jpg
  fi
  echo "== $MODE =="
  ls -l /tmp/one.jpg 2>&1
  $PY - <<'PYEOF'
import numpy as np, cv2
d = np.fromfile("/tmp/one.jpg", np.uint8)
print("  长度", len(d), " SOI", d[:2].tobytes().hex(), " EOI", d[-2:].tobytes().hex())
img = cv2.imdecode(d, cv2.IMREAD_GRAYSCALE)
if img is None:
    print("  解码失败")
else:
    print("  解码 %dx%d  mean=%.1f std=%.1f" % (img.shape[1], img.shape[0], img.mean(), img.std()))
PYEOF
done
