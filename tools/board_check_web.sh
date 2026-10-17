#!/bin/sh
# 验证 /api/sys 与 /snapshot.jpg?full=1
echo "== /api/sys"
curl -s --max-time 5 http://127.0.0.1:9012/api/sys
echo
echo "== snapshot full"
curl -s --max-time 15 -o /tmp/snap_full.jpg "http://127.0.0.1:9012/snapshot.jpg?full=1"
ls -l /tmp/snap_full.jpg
/opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import cv2
im = cv2.imread("/tmp/snap_full.jpg")
print("snapshot size:", None if im is None else (im.shape[1], im.shape[0]))
PY
echo "== snapshot stream-frame (full=0)"
curl -s --max-time 15 -o /tmp/snap_s.jpg "http://127.0.0.1:9012/snapshot.jpg?full=0"
/opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import cv2
im = cv2.imread("/tmp/snap_s.jpg")
print("stream-frame size:", None if im is None else (im.shape[1], im.shape[0]))
PY
