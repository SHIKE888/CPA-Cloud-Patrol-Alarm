#!/bin/bash
# 启动 RK3576 AI 标注推流服务（人体检测 + 姿态关键点 + 危险动作识别）
#
#   SRC   视频源：默认接入已有的 MJPEG 推流（不占用摄像头）；也可设 /dev/video22 直接采集
#   PORT  HTTP 端口（默认 9013）
#   AIFPS AI 帧率上限（默认 6，与视频帧率互不影响）
#
# 用法： bash start_ai.sh            # 默认参数
#        SRC=/dev/video22 bash start_ai.sh
#        bash start_ai.sh --zone "0.2,0.6;0.8,0.6;0.8,1;0.2,1"
set -e

PY=/opt/miniforge3/envs/mlk-ov/bin/python
AI=/root/rk/ai
SRC=${SRC:-http://127.0.0.1:9012/stream}
PORT=${PORT:-9013}
AIFPS=${AIFPS:-6}
CAPFPS=${CAPFPS:-25}
LOG=$AI/ai_webstream_$PORT.log

cd "$AI"

pkill -f "ai_webstream.py .*--port $PORT" 2>/dev/null || true
sleep 1

nohup $PY "$AI/board/ai_webstream.py" \
    --source "$SRC" \
    --port "$PORT" \
    --ai-fps "$AIFPS" \
    --cap-fps "$CAPFPS" \
    --det-model "$AI/models/yolov8n-slim.rknn" \
    --pose-model "$AI/models/yolov8n-pose-hybrid.rknn" \
    --stream-width 1280 --quality 72 --max-persons 4 \
    "$@" > "$LOG" 2>&1 &

echo "started pid=$!  log=$LOG"
sleep 4
tail -n 25 "$LOG"
echo
echo "浏览: http://$(hostname -I | awk '{print $1}'):$PORT/"
