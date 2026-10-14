#!/bin/bash
#=============================================================================
# path_test.sh —— 找出最快的高帧率通路 (60fps 的关键)
#
#   ./path_test.sh [/dev/video22] [帧数]
#
# 已有结论:
#   * v4l2src 纯采集 = 59.2 fps  -> 链路本身支持 1080p60
#   * 一旦管线里加编码/缩放就掉到 27~43 fps
#   * 怀疑: 采集格式 NV16(4:2:2) 不被 DRM/MPP 直接支持, 中间多了一次格式转换
# 这里对比 NV16 与 NV12 采集在"显示"和"硬件JPEG"两条路上的差别。
#=============================================================================
DEV="${1:-/dev/video22}"
N="${2:-200}"

try() {
    local name="$1"; shift
    local T0 T1 rc
    T0=$(date +%s%N)
    gst-launch-1.0 -q "$@" >/dev/null 2>&1
    rc=$?
    T1=$(date +%s%N)
    if [ $rc -ne 0 ]; then printf '  %-40s 失败\n' "$name"; return; fi
    awk -v n="$N" -v m="$(( (T1-T0)/1000000 ))" -v s="$name" \
        'BEGIN{printf "  %-40s %5d ms  %6.1f fps\n", s, m, n*1000/m}'
}

echo "=== 0. 显示设备状态 ==="
for s in /sys/class/drm/card*-HDMI-A-1/status; do
    [ -e "$s" ] && echo "  $s : $(cat $s)"
done
echo "  HDMI 支持的模式:"; head -3 /sys/class/drm/card*-HDMI-A-1/modes 2>/dev/null | sed 's/^/    /'
echo "  当前模式: $(cat /sys/class/drm/card*-HDMI-A-1/mode 2>/dev/null)"

echo
echo "=== 1. HDMI 显示路径: NV16 vs NV12 ==="
try "v4l2src(NV16) ! kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 '!' kmssink
try "v4l2src(NV12) ! kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,format=NV12,width=1920,height=1080 '!' kmssink
try "v4l2src(NV12) ! videoconvert ! kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,format=NV12,width=1920,height=1080 \
    '!' videoconvert '!' kmssink

echo
echo "=== 2. 硬件 JPEG: 输入格式的影响 ==="
try "NV16 ! mppjpegenc" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' mppjpegenc '!' fakesink
try "NV12 ! mppjpegenc" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,format=NV12,width=1920,height=1080 \
    '!' mppjpegenc '!' fakesink
try "NV16 ! videoconvert ! mppjpegenc" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 \
    '!' videoconvert '!' mppjpegenc '!' fakesink
try "NV12 ! mppjpegenc quality=60" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,format=NV12,width=1920,height=1080 \
    '!' mppjpegenc quality=60 '!' fakesink

echo
echo "=== 3. 参照: 纯采集上限 ==="
try "NV16 ! fakesink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,width=1920,height=1080 '!' fakesink
try "NV12 ! fakesink" \
    v4l2src device=$DEV num-buffers=$N '!' video/x-raw,format=NV12,width=1920,height=1080 '!' fakesink

echo
echo "=== 4. MPP 编码器能力 ==="
gst-inspect-1.0 mppjpegenc 2>/dev/null | sed -n '/^  [a-z]/p' | head -12
echo
echo "目标: 1080p60 = 16.7 ms/帧"
