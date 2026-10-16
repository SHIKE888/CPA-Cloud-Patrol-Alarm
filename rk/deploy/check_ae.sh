#!/bin/bash
# 检查 AE 状态机是否在推进 + 当前画面亮度
B=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

echo "=== CAM_WR_CNT / CAM_BUSY / 参数 (3 次, 间隔 2s) ==="
for i in 1 2 3; do
  curl -s -m 8 $B/api/fpga > /tmp/f.json
  printf "  "
  grep -o '"CAM_WR_CNT": [0-9]*' /tmp/f.json | tr '\n' ' '
  grep -o '"CAM_BUSY": [0-9]*' /tmp/f.json | tr '\n' ' '
  grep -o '"cam_exp_ms": [0-9.]*' /tmp/f.json | tr '\n' ' '
  grep -o '"cam_gain_db": [0-9.]*' /tmp/f.json | tr '\n' ' '
  grep -o '"ev": [-0-9]*' /tmp/f.json
  sleep 2
done

echo
echo "=== 当前画面 ==="
curl -s -m 12 --output /tmp/n.jpg $B/snapshot.jpg
$PY - <<'EOF'
import cv2
i = cv2.imread('/tmp/n.jpg', 0)
if i is None:
    print("  没抓到帧")
else:
    print("  平均亮度 = %.1f  (min %d max %d)" % (i.mean(), i.min(), i.max()))
EOF
