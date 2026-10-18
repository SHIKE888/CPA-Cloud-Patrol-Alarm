#!/bin/sh
pkill -f '[m]ipi_webstream.py'
sleep 2
echo "== mode: $(i2cget -y 9 0x40 0xe0)"
rm -f /tmp/seq4k.nv16
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16 \
  --stream-mmap --stream-count=12 --stream-to=/tmp/seq4k.nv16 2>&1 | tail -2
ls -l /tmp/seq4k.nv16
/opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import hashlib
import numpy as np

FS = 3840 * 2160 * 2
d = np.fromfile("/tmp/seq4k.nv16", np.uint8)
n = len(d) // FS
print("raw frames:", n)
prev = None
for i in range(n):
    f = d[i * FS:(i + 1) * FS]
    md = hashlib.md5(f.tobytes()).hexdigest()[:10]
    y = f[:3840 * 2160]
    print("  #%02d %s  Ymean=%.2f  Ystd=%.2f  %s"
          % (i, md, y.mean(), y.std(), "<-- 与上一帧完全相同" if md == prev else ""))
    prev = md
PY
