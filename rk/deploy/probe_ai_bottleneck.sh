#!/bin/bash
# probe_ai_bottleneck.sh —— 采集 YOLO 帧率瓶颈的证据（NPU 占用 / 各阶段耗时 / 线程 CPU）
# 用法: bash probe_ai_bottleneck.sh [端口=9012]
PORT=${1:-9012}

echo "=== /api/ai @ $PORT ==="
curl -s --max-time 8 "http://127.0.0.1:$PORT/api/ai" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in ('enabled','source','fps','fps_target','fps_det','fps_pose','run_ms',
          'det_ms','pose_ms','track_ms','sync_ms','persons','preset','ai_fps',
          'det_interval','copy_frame'):
    print('  %-13s %s' % (k, d.get(k)))
print('  models       ', d.get('models'))
"

echo "=== rknpu load x6 ==="
for i in 1 2 3 4 5 6; do
    cat /sys/kernel/debug/rknpu/load 2>/dev/null || echo "(no rknpu debugfs)"
    sleep 1
done

echo "=== 线程时钟 (top -H) ==="
PID=$(pgrep -f "mipi_webstream[.]py" | head -1)
echo "PID=$PID"
top -H -b -n 2 -d 1 -p "$PID" | tail -20

echo "=== 线程名对照 ==="
for t in /proc/"$PID"/task/*; do
    printf "%s %s\n" "$(basename "$t")" "$(cat "$t/comm" 2>/dev/null)"
done | sort -n | head -40

echo "=== uptime ==="
uptime
