#!/bin/bash
#=============================================================================
# hdmi_view.sh —— FPGA 摄像头画面直接输出到 HDMI（已优化的高帧率版本）
#
#   ./hdmi_view.sh [设备] [宽度] [高度]
#   ./hdmi_view.sh                     # 默认 /dev/video22, 1920x1080, 缩放到屏幕原生
#
# 关键点（易踩坑，务必保留）：
#   1. 采集后必须立刻接 queue —— 否则采集和上屏在同一线程里串行，
#      耗时相加，帧率只有 ~28fps；接上 queue 后并行，能到 ~50fps。
#   2. queue 深度 3~8 最佳；1~2 太浅(37fps)、16 太深(29fps) 都会掉。
#   3. 缩放成屏幕原生分辨率（本机 1440x900）比直接 1080p 上屏更快（53.7 vs 49.8）。
#
# 实测：优化前 27.7 fps  ->  优化后 53.7 fps（采集上限是 57.6 fps）
#=============================================================================
set -u

DEV="${1:-/dev/video22}"
W="${2:-1920}"
H="${3:-1080}"

# 查当前屏幕实际模式（形如 1440x900p60）
MODE=""
if [ -r /sys/kernel/debug/dri/0/summary ]; then
    MODE=$(grep -m1 "Display mode:" /sys/kernel/debug/dri/0/summary 2>/dev/null \
           | sed 's/.*Display mode:[[:space:]]*//; s/p[0-9]*$//')
fi

echo "设备        : $DEV"
echo "采集分辨率  : ${W}x${H}"
echo "屏幕模式    : ${MODE:-未知}"

if [ -n "$MODE" ] && [ "$MODE" != "${W}x${H}" ]; then
    SW="${MODE%%x*}"
    SH="${MODE##*x}"
    echo "策略        : 缩放到屏幕原生 ${SW}x${SH}（比直接上屏更快）"
    echo

    # 用 videoscale 显式缩放，并夹两个 queue 做流水线
    exec gst-launch-1.0 -q \
        v4l2src device="$DEV" ! \
        "video/x-raw,width=${W},height=${H}" ! \
        queue max-size-buffers=4 ! \
        videoscale ! "video/x-raw,width=${SW},height=${SH}" ! \
        queue max-size-buffers=4 ! \
        kmssink
else
    echo "策略        : 分辨率与屏幕一致，直接上屏"
    echo

    exec gst-launch-1.0 -q \
        v4l2src device="$DEV" ! \
        "video/x-raw,width=${W},height=${H}" ! \
        queue max-size-buffers=4 ! \
        videoconvert ! \
        queue max-size-buffers=4 ! \
        kmssink
fi
