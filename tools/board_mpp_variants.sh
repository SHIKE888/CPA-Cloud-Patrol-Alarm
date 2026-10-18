#!/bin/sh
# 连续 20 帧 x 4 种 gst 写法, 看哪种不产灰帧
PY=/opt/miniforge3/envs/mlk-ov/bin/python
pkill -f 'gst-launch-1.0 -q fdsrc' 2>/dev/null
sleep 1
[ -f /tmp/in20.nv12 ] || cat /tmp/small.nv12 /tmp/small.nv12 /tmp/small.nv12 /tmp/small.nv12 /tmp/small.nv12 > /tmp/in20.nv12

run() {
  name=$1
  shift
  rm -f /tmp/o_$name.mjpg
  cat /tmp/in20.nv12 | gst-launch-1.0 -q "$@" ! multipartmux boundary=framebnd ! filesink location=/tmp/o_$name.mjpg 2>/tmp/e_$name.txt
  NAME=$name $PY - <<'PYEOF'
import os
import numpy as np, cv2
name = os.environ["NAME"]
BND = b"--framebnd"
try:
    d = open("/tmp/o_%s.mjpg" % name, "rb").read()
except Exception:
    print("%-10s 无输出" % name)
    raise SystemExit
parts = d.split(BND)
tot = bad = 0
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
    tot += 1
    if img is None or float(img.std()) < 3.0:
        bad += 1
print("%-10s 总 %d 段, 灰/坏 %d" % (name, tot, bad))
PYEOF
}

run plain \
  fdsrc fd=0 blocksize=2519424 ! rawvideoparse format=nv12 width=1728 height=972 ! mppjpegenc
run caps \
  fdsrc fd=0 blocksize=2519424 ! rawvideoparse format=nv12 width=1728 height=972 ! video/x-raw,format=NV12,width=1728,height=972 ! mppjpegenc
run queuein \
  fdsrc fd=0 blocksize=2519424 ! rawvideoparse format=nv12 width=1728 height=972 ! queue ! mppjpegenc
run queueout \
  fdsrc fd=0 blocksize=2519424 ! rawvideoparse format=nv12 width=1728 height=972 ! mppjpegenc ! queue
