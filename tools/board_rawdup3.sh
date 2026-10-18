#!/bin/sh
# 用法: sh /tmp/rd3.sh 1080|4k
M=${1:-4k}
pkill -f '[m]ipi_webstream.py'
sleep 2
if [ "$M" = "1080" ]; then bash /root/start.sh 1080 >/tmp/s13.log 2>&1
else bash /root/start.sh 4k >/tmp/s13.log 2>&1; fi
sleep 6
rm -f /tmp/seq3.nv16
v4l2-ctl -d /dev/video22 --stream-mmap --stream-count=10 --stream-to=/tmp/seq3.nv16 >/dev/null 2>&1
for i in $(seq 1 20); do [ -s /tmp/seq3.nv16 ] && break; sleep 0.2; done
MODE=$M /opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import hashlib, os
import numpy as np

mode = os.environ.get("MODE", "4k")
W, H = (1920, 1080) if mode == "1080" else (3840, 2160)
FS = W * H * 2
d = np.fromfile("/tmp/seq3.nv16", np.uint8)
n = len(d) // FS
print("mode", mode, "raw frames:", n)
prev = None
uniq = 0
for i in range(n):
    f = d[i * FS:(i + 1) * FS]
    md = hashlib.md5(f.tobytes()).hexdigest()[:10]
    y = f[:W * H]
    if md != prev:
        uniq += 1
    print("  #%02d %s Ymean=%.2f Ystd=%.3f %s"
          % (i, md, y.mean(), y.std(), "<== 与上一帧相同" if md == prev else ""))
    prev = md
print("unique: %d / %d" % (uniq, n))
PY
