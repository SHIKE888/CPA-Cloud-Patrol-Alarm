#!/bin/bash
#=============================================================================
# test_fps120.sh —— 验证「帧率上限」放宽到 120 后的行为
#
#   ./test_fps120.sh
#
# 期望:
#   * POST {"fps":120} 被接受
#   * 实际帧率仍 ≈59.6 (链路固定 1080p60, 限速阀放到 120 = 不限速)
#   * POST {"fps":999} 被裁剪到 120
#   * POST {"fps":30}  能真的限到 30
#=============================================================================
PORT=9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python
W=/root/rk/web

pkill -f 'mipi_web[s]tream' 2>/dev/null
sleep 1
cd "$W" || exit 1

nohup ./start_webstream.sh /dev/video22 $PORT --backend opencv \
    --stream-width 1920 > /tmp/ws.log 2>&1 &
sleep 8

get_fps() {
    curl -s --max-time 4 "http://127.0.0.1:$PORT/api/status" \
        | tr ',' '\n' | grep -m1 '"fps"' | cut -d: -f2 | tr -d ' '
}

set_fps() {
    curl -s --max-time 4 -X POST "http://127.0.0.1:$PORT/api/params" \
        -H 'Content-Type: application/json' -d "{\"fps\":$1}" \
        | tr ',' '\n' | grep -m1 '"fps"' | cut -d: -f2 | tr -d ' '
}

echo "=== 启动后基线 (默认 fps=60) ==="
echo "  服务上报 fps: $(get_fps)"
printf '  实测帧率: '
for i in 1 2 3; do sleep 1; printf '%s ' "$(get_fps)"; done
echo

echo
echo "=== POST fps=120 ==="
echo "  参数被接受为: $(set_fps 120)"
printf '  实测帧率: '
for i in 1 2 3 4; do sleep 1; printf '%s ' "$(get_fps)"; done
echo
echo "  ^ 仍应 ≈59.6 —— 说明瓶颈是链路, 不是限速阀"

echo
echo "=== POST fps=999 (应被裁剪到 120) ==="
echo "  参数被接受为: $(set_fps 999)"

echo
echo "=== POST fps=30 (应真的限到 30) ==="
echo "  参数被接受为: $(set_fps 30)"
printf '  实测帧率: '
for i in 1 2 3 4; do sleep 1; printf '%s ' "$(get_fps)"; done
echo

echo
echo "=== 复位到 60 ==="
echo "  参数被接受为: $(set_fps 60)"
printf '  实测帧率: '
for i in 1 2 3; do sleep 1; printf '%s ' "$(get_fps)"; done
echo

echo
echo "=== 服务日志 (前 12 行) ==="
head -12 /tmp/ws.log
