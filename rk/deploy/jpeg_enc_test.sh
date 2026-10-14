#!/bin/bash
#=============================================================================
# jpeg_enc_test.sh —— 找出能跑 1080p60 的 JPEG 编码方案
#
#   ./jpeg_enc_test.sh [/dev/video22] [帧数]
#
# 背景: 已实测 v4l2src 纯采集 = 59.2 fps (链路足够 1080p60),
#       但软件 jpegenc 只能 29.3 fps (34.1ms/帧) —— 瓶颈在编码。
#       1080p60 需要 16.7 ms/帧, 即编码必须 <= ~10ms/帧。
# 本脚本枚举可用编码器(软件/硬件)并实测吞吐。
#=============================================================================
DEV="${1:-/dev/video22}"
N="${2:-200}"
SRC="v4l2src device=$DEV num-buffers=$N ! video/x-raw,width=1920,height=1080"

try() {
    local name="$1"; shift
    local T0 T1 rc
    T0=$(date +%s%N)
    gst-launch-1.0 -q "$@" >/dev/null 2>&1
    rc=$?
    T1=$(date +%s%N)
    if [ $rc -ne 0 ]; then printf '  %-36s 不可用 / 管线失败\n' "$name"; return; fi
    awk -v n="$N" -v m="$(( (T1-T0)/1000000 ))" -v s="$name" \
        'BEGIN{printf "  %-36s %5d ms  %6.1f fps  (%5.1f ms/帧)\n", s, m, n*1000/m, m/n}'
}

echo "=== 1. JPEG 相关元素 ==="
gst-inspect-1.0 2>/dev/null | grep -iE "jpeg|mpp|rockchip" | head -20

echo
echo "=== 2. 硬件编解码设备节点 ==="
for d in /dev/mpp_service /dev/video-encoder /dev/video-decoder \
         /dev/video-dec0 /dev/rkvenc /dev/rkvdec; do
    [ -e "$d" ] && ls -l "$d"
done
echo "  (如果上面为空, 说明没暴露 MPP/V4L2-M2M 节点)"

echo
echo "=== 3. 1080p 各路编码吞吐 ($N 帧, 目标 >=60fps) ==="
try "软件 jpegenc (基准)" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' jpegenc quality=80 '!' fakesink
try "mppjpegenc (RK 硬件 MPP)" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' mppjpegenc '!' fakesink
try "v4l2jpegenc (V4L2 硬件)" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' v4l2jpegenc '!' fakesink
try "avenc_mjpeg (libav 多线程)" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' avenc_mjpeg threads=8 '!' fakesink
try "jpegenc + 2路 tee 并行" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' tee name=t t. '!' queue '!' jpegenc quality=80 '!' fakesink \
    t. '!' queue '!' fakesink

echo
echo "=== 4. 显示路径(HDMI)吞吐 ==="
try "v4l2src ! kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 '!' kmssink
try "1080p60 换算: 16.7 ms/帧"

echo
echo "=== 5. 各分辨率下软件 jpegenc 的能力 ==="
for wh in 1920x1080 1280x720 960x540; do
    w=${wh%x*}; h=${wh#*x}
    try "jpegenc ${wh}" \
        v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
        '!' videoscale '!' video/x-raw,width=$w,height=$h '!' jpegenc quality=80 '!' fakesink
done
