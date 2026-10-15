#!/bin/bash
# 曝光/增益/EV 是否真的影响画面 —— 用帧平均亮度做定量 A/B
B=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

mean() {
  curl -s -m 15 --output /tmp/m.jpg $B/snapshot.jpg
  $PY - <<'EOF'
import cv2, sys
img = cv2.imread('/tmp/m.jpg', cv2.IMREAD_GRAYSCALE)
if img is None:
    print("  !! 没抓到帧")
    sys.exit()
h, w = img.shape
print("  %dx%d  平均亮度=%.1f  最小=%d 最大=%d  中位=%.0f"
      % (w, h, img.mean(), img.min(), img.max(),
         float(__import__('numpy').median(img))))
EOF
}

wr() {
  printf "  写入 %s -> " "$1"
  curl -s -m 15 -X POST -H 'Content-Type: application/json' -d "$1" $B/api/fpga \
    | grep -o '"message": "[^"]*"'
}

echo "=== 0. 基线 ==="
mean
curl -s -m 8 $B/api/fpga | grep -o '"cam_exp_ms": [0-9.]*\|"cam_gain_db": [0-9.]*\|"CAM_WR_CNT": [0-9]*'

echo
echo "=== 1. 曝光 0.5ms (应大幅变暗) ==="
wr '{"cam_exp_ms":0.5}'; sleep 3; mean

echo
echo "=== 2. 曝光 16.6ms (应大幅变亮) ==="
wr '{"cam_exp_ms":16.6}'; sleep 3; mean

echo
echo "=== 3. 增益 0dB (应明显变暗) ==="
wr '{"cam_gain_db":0}'; sleep 3; mean

echo
echo "=== 4. 增益 30dB (应明显变亮) ==="
wr '{"cam_gain_db":30}'; sleep 3; mean

echo
echo "=== 5. EV +3 / -3 ==="
wr '{"ev":3}'; sleep 3; mean
wr '{"ev":-3}'; sleep 3; mean

echo
echo "=== 6. 恢复默认 ==="
wr '{"cam_exp_ms":16.6,"cam_gain_db":14.4,"ev":0,"wb_r_pct":100,"wb_b_pct":100}'
sleep 2
curl -s -m 8 $B/api/fpga | grep -o '"cam_exp_ms": [0-9.]*\|"cam_gain_db": [0-9.]*\|"CAM_WR_CNT": [0-9]*\|"CAM_BUSY": [0-9]*'
