#!/bin/bash
#=============================================================================
# display_test.sh —— 判断 60fps 的卡点到底在"显示通路"还是"采集通路"
#
#   ./display_test.sh [/dev/video22]
#
# 思路:
#   * videotestsrc 是纯内存源, 与摄像头无关 —— 用它测"显示通路"的上限
#   * v4l2src 是真实采集 —— 用它测"采集+显示"
#   两者一比就知道卡在哪
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
    if [ $rc -ne 0 ]; then printf '  %-46s 失败\n' "$name"; return; fi
    awk -v n="$N" -v m="$(( (T1-T0)/1000000 ))" -v s="$name" \
        'BEGIN{printf "  %-46s %6.1f fps  (%5.1f ms/帧)\n", s, n*1000/m, m/n}'
}

echo "=== 1. 显示通路上限 (纯内存源, 与摄像头无关) ==="
try "videotestsrc 1080p -> kmssink" \
    videotestsrc num-buffers=$N '!' video/x-raw,width=1920,height=1080 '!' kmssink
try "videotestsrc 1080p -> fakesink" \
    videotestsrc num-buffers=$N '!' video/x-raw,width=1920,height=1080 '!' fakesink
try "videotestsrc 720p  -> kmssink" \
    videotestsrc num-buffers=$N '!' video/x-raw,width=1280,height=720 '!' kmssink

echo
echo "=== 2. 采集 + 显示 ==="
try "v4l2src 1080p -> kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 '!' kmssink

echo
echo "=== 3. 网页推流可用编码方案 (加 queue 后) ==="
try "1080p jpegenc + queue" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' queue max-size-buffers=8 leaky=downstream '!' jpegenc quality=80 '!' fakesink
try "720p  videoscale + jpegenc + queue" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' queue max-size-buffers=8 leaky=downstream '!' videoscale \
    '!' video/x-raw,width=1280,height=720 '!' jpegenc quality=80 '!' fakesink
try "960x540 jpegenc + queue" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' queue max-size-buffers=8 leaky=downstream '!' videoscale \
    '!' video/x-raw,width=960,height=540 '!' jpegenc quality=80 '!' fakesink

echo
echo "=== 4. 当前 HDMI 实际模式/刷新率 ==="
modetest -c 2>/dev/null | sed -n '/props:/q;p' | grep -A3 "Connectors:" 
echo "  --- CRTC ---"
modetest -p 2>/dev/null | grep -iE "CRTC|ACTIVE|MODE_ID" | head -10
echo "  --- /sys 里的当前模式 ---"
for f in /sys/class/drm/card0-HDMI-A-1/mode \
         /sys/class/drm/card0-HDMI-A-1/enabled \
         /sys/class/drm/card0-HDMI-A-1/dpms; do
    echo "    $(basename $f) = $(cat $f 2>/dev/null)"
done
