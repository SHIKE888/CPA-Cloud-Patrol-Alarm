#!/bin/bash
#=============================================================================
# affinity_test.sh —— CPU 亲和性对 1080p JPEG 编码帧率的影响
#
# 背景: cv2.imencode 单核在 A72 上是 17.9ms/帧 (55.8fps),
#       但之前 gst 管线里 jpegenc 量到 24.1ms/帧 (41.5fps)。
#       怀疑进程被调度到 A53 小核, 或被限频。
#
# 本机: cpu0-3 = Cortex-A53 @1.92GHz, cpu4-7 = Cortex-A72 @2.11GHz
#=============================================================================
DEV="${1:-/dev/video22}"
N="${2:-300}"

try() {
    local name="$1"; shift
    local T0 T1 rc
    T0=$(date +%s%N)
    "$@" >/dev/null 2>&1
    rc=$?
    T1=$(date +%s%N)
    if [ $rc -ne 0 ]; then printf '  %-46s 失败\n' "$name"; return; fi
    awk -v n="$N" -v m="$(( (T1-T0)/1000000 ))" -v s="$name" \
        'BEGIN{printf "  %-46s %6.1f fps  (%5.1f ms/帧)\n", s, n*1000/m, m/n}'
}

V="video/x-raw,width=1920,height=1080"

echo "当前 CPU 频率(前 8 核, MHz):"
for i in 0 1 2 3 4 5 6 7; do
    f=$(cat /sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq 2>/dev/null)
    printf '  cpu%d=%s' "$i" "$(( ${f:-0} / 1000 ))"
done
echo; echo

echo "=== 不限制亲和性 ==="
try "v4l2src ! queue ! jpegenc ! fakesink" \
    gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=4 '!' jpegenc '!' fakesink

echo
echo "=== 只跑 A53 小核 (cpu0-3) ==="
try "taskset -c 0-3  jpegenc" \
    taskset -c 0-3 gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=4 '!' jpegenc '!' fakesink

echo
echo "=== 只跑 A72 大核 (cpu4-7) ==="
try "taskset -c 4-7  jpegenc" \
    taskset -c 4-7 gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=4 '!' jpegenc '!' fakesink

echo
echo "=== 单核各种绑定 ==="
for c in 0 4; do
    try "taskset -c $c  jpegenc" \
        taskset -c $c gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=4 '!' jpegenc '!' fakesink
done

echo
echo "=== A72 上 + 提高性能模式 ==="
for g in performance schedutil; do
    for i in 4 5 6 7; do
        echo $g > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor 2>/dev/null
    done
    try "governor=$g  taskset 4-7  jpegenc" \
        taskset -c 4-7 gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=4 '!' jpegenc '!' fakesink
done

echo
echo "=== 参照: A72 上的采集上限 ==="
try "taskset -c 4-7  v4l2src ! fakesink" \
    taskset -c 4-7 gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N '!' $V '!' fakesink

echo
echo "=== 参照: A72 上的显示通路 ==="
try "taskset -c 4-7  双queue ! kmssink" \
    taskset -c 4-7 gst-launch-1.0 -q v4l2src device=$DEV num-buffers=$N '!' $V \
    '!' queue max-size-buffers=4 '!' videoconvert '!' queue max-size-buffers=4 '!' kmssink
