#!/bin/sh
pkill -f '[m]ipi_webstream.py'
sleep 2
rm -f /tmp/seq.nv16
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16 \
  --stream-mmap --stream-count=10 --stream-to=/tmp/seq.nv16 >/dev/null 2>&1
ls -l /tmp/seq.nv16
/opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import hashlib
import numpy as np

FS = 3840 * 2160 * 2
d = np.fromfile("/tmp/seq.nv16", np.uint8)
n = len(d) // FS
print("raw frames:", n)
prev = None
for i in range(n):
    f = d[i * FS:(i + 1) * FS]
    md = hashlib.md5(f.tobytes()).hexdigest()[:10]
    y = f[:3840 * 2160]
    print("  #%02d %s Ymean=%.2f Ystd=%.3f %s"
          % (i, md, y.mean(), y.std(), "<== 与上一帧相同" if md == prev else ""))
    prev = md
PY
bash /root/start.sh 4k >/tmp/s12.log 2>&1
