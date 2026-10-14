#!/bin/bash
#=============================================================================
# overlap_test.sh —— 验证"加 queue 让采集与编码流水线并行"能否冲到 60fps
#
#   ./overlap_test.sh [/dev/video22] [帧数]
#
# 观察: 之前测到
#   纯采集      = 17.6 ms/帧 (56.9 fps)
#   mppjpegenc  = 再加 8.5 ms -> 26.1 ms (38.5 fps)
# 说明采集与编码是"串行相加"的, 没有重叠 —— 加 queue 让它们在不同线程跑,
# 吞吐应变成 max(采集, 编码) 而不是 sum。
#=============================================================================
DEV="${1:-/dev/video22}"
N="${2:-300}"
SRC16="v4l2src device=$DEV num-buffers=$N ! video/x-raw,width=1920,height=1080"

try() {
    local name="$1"; shift
    local T0 T1 rc
    T0=$(date +%s%N)
    gst-launch-1.0 -q "$@" >/dev/null 2>&1
    rc=$?
    T1=$(date +%s%N)
    if [ $rc -ne 0 ]; then printf '  %-44s 失败\n' "$name"; return; fi
    awk -v n="$N" -v m="$(( (T1-T0)/1000000 ))" -v s="$name" \
        'BEGIN{printf "  %-44s %5d ms  %6.1f fps  (%5.1f ms/帧)\n", s, m, n*1000/m, m/n}'
}

echo "=== 1. 无 queue (串行) vs 有 queue (并行) ==="
try "mppjpegenc 无 queue" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' mppjpegenc '!' fakesink
try "mppjpegenc + queue" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' queue max-size-buffers=8 leaky=downstream '!' mppjpegenc '!' fakesink
try "jpegenc 无 queue" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' jpegenc quality=80 '!' fakesink
try "jpegenc + queue" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' queue max-size-buffers=8 leaky=downstream '!' jpegenc quality=80 '!' fakesink

echo
echo "=== 2. 显示通路 ==="
try "kmssink (默认 sync)" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 '!' kmssink
try "kmssink sync=false" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' kmssink sync=false
try "queue + kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' queue max-size-buffers=4 '!' kmssink

echo
echo "=== 3. HDMI 连接器/模式详情 ==="
if command -v modetest >/dev/null 2>&1; then
    modetest -c 2>/dev/null | head -40
else
    echo "  (没有 modetest)"
    cat /sys/class/drm/card0-HDMI-A-1/modes 2>/dev/null | sed 's/^/    /'
    echo "  enabled: $(cat /sys/class/drm/card0-HDMI-A-1/enabled 2>/dev/null)"
    echo "  dpms:    $(cat /sys/class/drm/card0-HDMI-A-1/dpms 2>/dev/null)"
fi

echo
echo "目标: 1080p60 = 16.7 ms/帧"
