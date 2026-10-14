#!/bin/bash
#=============================================================================
# kms_tune.sh —— 把 kmssink 从 41 fps 继续往上推
#   ./kms_tune.sh [/dev/video22] [帧数]
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
    if [ $rc -ne 0 ]; then printf '  %-52s 失败\n' "$name"; return; fi
    awk -v n="$N" -v m="$(( (T1-T0)/1000000 ))" -v s="$name" \
        'BEGIN{printf "  %-52s %6.1f fps  (%5.1f ms/帧)\n", s, n*1000/m, m/n}'
}

V="video/x-raw,width=1920,height=1080"
V12="video/x-raw,width=1920,height=1080,format=NV12"
V16="video/x-raw,width=1920,height=1080,format=NV16"

echo "=== 基准 ==="
try "queue(4) ! kmssink"                    v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=4 '!' kmssink
try "queue(16) ! kmssink"                   v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=16 '!' kmssink
try "queue(16) ! kmssink sync=false"        v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=16 '!' kmssink sync=false

echo
echo "=== 换格式: 看 kmssink 是否在做 CPU 颜色转换 ==="
try "NV16 输入 ! queue ! kmssink"           v4l2src device=$DEV num-buffers=$N '!' $V16 '!' queue max-size-buffers=16 '!' kmssink
try "NV12 输入 ! queue ! kmssink"           v4l2src device=$DEV num-buffers=$N '!' $V12 '!' queue max-size-buffers=16 '!' kmssink
try "NV12 ! queue ! videoconvert ! kmssink" v4l2src device=$DEV num-buffers=$N '!' $V12 '!' queue max-size-buffers=16 '!' videoconvert '!' kmssink
try "NV12 -> BGRx ! queue ! kmssink"        v4l2src device=$DEV num-buffers=$N '!' $V12 '!' videoconvert '!' video/x-raw,format=BGRx '!' queue max-size-buffers=16 '!' kmssink

echo
echo "=== 双 queue (更彻底的流水线) ==="
try "queue ! videoconvert ! queue ! kmssink" v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=16 '!' videoconvert '!' queue max-size-buffers=16 '!' kmssink

echo
echo "=== 上限参照 ==="
try "采集上限 fakesink"                     v4l2src device=$DEV num-buffers=$N '!' $V '!' fakesink
try "queue ! videoconvert ! fakesink"       v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=16 '!' videoconvert '!' video/x-raw,format=BGRx '!' fakesink
try "queue ! videoscale 1440x900 ! fakesink" v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=16 '!' videoscale '!' video/x-raw,width=1440,height=900 '!' videoconvert '!' video/x-raw,format=BGRx '!' fakesink
