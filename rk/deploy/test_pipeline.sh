#!/bin/bash
#=============================================================================
# test_pipeline.sh —— 启动优化后的推流服务并测真实帧率
#
#   ./test_pipeline.sh [秒数]
#
# 会打印: 服务日志头几行、/api/status、以及快照的尺寸/大小
#=============================================================================
SECS="${1:-12}"
PORT=9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python
W=/root/rk/web

pkill -f 'mipi_web[s]tream' 2>/dev/null
sleep 1

cd "$W" || exit 1

# 没编译过 C 库就编一下
[ -f libyuvconv.so ] || ./build_yuvconv.sh

echo "=== 启动 (opencv 后端, 1920x1080 推流) ==="
nohup "$PY" mipi_webstream.py \
    --backend opencv \
    --device /dev/video22 \
    --port $PORT \
    --width 1920 --height 1080 \
    --stream-width 1920 \
    --conv-threads 4 --enc-threads 3 \
    > /tmp/ws.log 2>&1 &
echo "PID $!"

sleep "$SECS"

echo
echo "=== 服务日志 ==="
head -20 /tmp/ws.log

echo
echo "=== /api/status ==="
curl -s --max-time 5 "http://127.0.0.1:$PORT/api/status" || echo "(取不到)"

echo
echo "=== 采样 8 秒看帧率 ==="
for i in 1 2 3 4 5 6 7 8; do
    s=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/api/status")
    f=$(echo "$s" | tr ',' '\n' | grep -m1 '"fps"' | cut -d: -f2)
    printf '  t=%ds  fps=%s\n' "$i" "$f"
    sleep 1
done

echo
echo "=== 抓一张快照 ==="
curl -s --max-time 5 -o /tmp/snap.jpg "http://127.0.0.1:$PORT/snapshot.jpg"
ls -l /tmp/snap.jpg 2>/dev/null
"$PY" - <<'EOF'
import cv2, numpy as np
img = cv2.imread("/tmp/snap.jpg")
if img is None:
    print("  快照读取失败"); raise SystemExit
h, w = img.shape[:2]
print("  尺寸 %dx%d" % (w, h))
b, g, r = [float(img[:, :, i].mean()) for i in range(3)]
print("  平均 B/G/R = %.1f / %.1f / %.1f  (三通道接近说明不偏色)" % (b, g, r))
print("  灰度等级 %.1f (0=全黑 255=全白, 说明曝光/量程)" % img.mean())
EOF

echo
echo "=== 停止 ==="
pkill -f 'mipi_web[s]tream' 2>/dev/null
sleep 1
echo "已停止"
