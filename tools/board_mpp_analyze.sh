#!/bin/sh
PY=/opt/miniforge3/envs/mlk-ov/bin/python
pkill -f 'gst-launch-1.0 -q fdsrc' 2>/dev/null
$PY - <<'PYEOF'
import glob
import numpy as np
import cv2

BND = b"--framebnd"
for f in sorted(glob.glob("/tmp/o_*.mjpg")):
    name = f.split("/")[-1][2:-5]
    d = open(f, "rb").read()
    tot = bad = 0
    stds = []
    for p in d.split(BND):
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
        if img is None:
            bad += 1
            stds.append(-1)
        else:
            s = float(img.std())
            stds.append(round(s, 1))
            if s < 3.0:
                bad += 1
    print("%-9s 段数 %3d  灰/坏 %3d  std样本 %s" % (name, tot, bad, stds[:8]))
PYEOF
