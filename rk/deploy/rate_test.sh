#!/bin/bash
#=============================================================================
# rate_test.sh —— 测出链路上各环节的真实帧率上限
#
#   ./rate_test.sh [/dev/video22] [帧数]
#
# 目的: 判断 1080p60 是否可行 —— 分别看"纯采集"和"各级处理"的吞吐。
#       1080p60 需要 16.7 ms/帧。
#=============================================================================
DEV="${1:-/dev/video22}"
N="${2:-400}"
W=1920; H=1080

fps() { awk -v n="$1" -v m="$2" \
        'BEGIN{ if (m<=0) m=1; printf "%6d ms / %3d 帧 = %6.1f fps  (%.1f ms/帧)", m, n, n*1000/m, m/n }'; }

run() {
    local name="$1"; shift
    local T0 T1
    T0=$(date +%s%N)
    "$@" >/dev/null 2>&1
    T1=$(date +%s%N)
    printf '  %-44s %s\n' "$name" "$(fps $N $(( (T1-T0)/1000000 )))"
}

echo "设备 $DEV   每组 $N 帧    (1080p60 = 16.7 ms/帧)"
echo
echo "=== A. 纯采集 (不做任何处理) ==="
run "v4l2-ctl 直接抓 NV16" \
    v4l2-ctl -d $DEV --set-fmt-video=width=$W,height=$H,pixelformat=NV16 \
        --stream-mmap --stream-count=$N --stream-to=/dev/null
run "gst v4l2src ! fakesink" \
    gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N ! fakesink

echo
echo "=== B. 加处理 ==="
run "gst + jpegenc (1080p JPEG)" \
    gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N ! jpegenc quality=80 ! fakesink
run "gst + videoscale 720p + jpegenc" \
    gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N ! \
        videoscale ! video/x-raw,width=1280,height=720 ! jpegenc quality=80 ! fakesink
run "gst + videoconvert + jpegenc (1080p RGB)" \
    gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N ! \
        videoconvert ! jpegenc quality=80 ! fakesink

echo
echo "=== C. 采集端能力 (不抓流, 只看节点支持的格式/帧率) ==="
v4l2-ctl -d $DEV --list-formats-ext 2>/dev/null | head -30
echo
echo "=== D. 内核里关于帧率的线索 ==="
dmesg 2>/dev/null | grep -iE "fps|frame.*rate|vblank|timeout.*frame" | tail -8
