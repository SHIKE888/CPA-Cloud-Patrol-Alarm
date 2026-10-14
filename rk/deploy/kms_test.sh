#!/bin/bash
#=============================================================================
# kms_test.sh —— 验证 kmssink 的 ~28fps 是否是"尺寸不匹配"造成的
#
#   ./kms_test.sh [/dev/video22] [帧数]
#
# 现状: 显示器跑 1440x900p60, 视频是 1920x1080 -> 尺寸不一致。
#   /sys/kernel/debug/dri/0/summary 显示 win0 src=dst=1440x900 (无缩放)
#=============================================================================
DEV="${1:-/dev/video22}"
N="${2:-300}"

try() {
    local name="$1"; shift
    local T0 T1 rc
    T0=$(date +%s%N)
    gst-launch-1.0 -q "$@" >/dev/null 2>&1
    rc=$?
    T1=$(date +%s%N)
    if [ $rc -ne 0 ]; then printf '  %-50s 失败\n' "$name"; return; fi
    awk -v n="$N" -v m="$(( (T1-T0)/1000000 ))" -v s="$name" \
        'BEGIN{printf "  %-50s %6.1f fps  (%5.1f ms/帧)\n", s, n*1000/m, m/n}'
}

echo "当前显示模式:"
grep -E "Display mode|fixed" /sys/kernel/debug/dri/0/summary 2>/dev/null | head -2 | sed 's/^/  /'
echo

echo "=== kmssink: 视频尺寸与显示模式的关系 ==="
try "原始 1920x1080 -> kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 '!' kmssink
try "缩到 1440x900(与屏幕一致) -> kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' videoscale '!' video/x-raw,width=1440,height=900 '!' kmssink
try "缩到 1280x720 -> kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' videoscale '!' video/x-raw,width=1280,height=720 '!' kmssink
try "kmssink 加 queue" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' queue max-size-buffers=4 '!' kmssink
try "kmssink 只测 sink 上游(不接摄像头, 看同一 buffer 反复上屏)" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' identity drop-probability=0 '!' kmssink

echo
echo "=== 参照: 采集上限 & 纯编码上限 ==="
try "采集上限 v4l2src ! fakesink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 '!' fakesink
try "1080p jpegenc + queue" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' queue max-size-buffers=4 '!' jpegenc quality=80 '!' fakesink
