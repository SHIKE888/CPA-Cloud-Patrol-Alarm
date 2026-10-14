#!/bin/bash
#=============================================================================
# kms_tune2.sh —— 锁定 kmssink 最佳参数 (当前最好: 双 queue = 50 fps)
#   ./kms_tune2.sh [/dev/video22] [帧数]
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
    if [ $rc -ne 0 ]; then printf '  %-56s 失败\n' "$name"; return; fi
    awk -v n="$N" -v m="$(( (T1-T0)/1000000 ))" -v s="$name" \
        'BEGIN{printf "  %-56s %6.1f fps  (%5.1f ms/帧)\n", s, n*1000/m, m/n}'
}

V="video/x-raw,width=1920,height=1080"

echo "=== queue 深度扫描 (videoconvert 夹在中间) ==="
for q in 2 3 4 6 8; do
    try "queue($q) ! videoconvert ! queue($q) ! kmssink" \
        v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=$q '!' videoconvert '!' queue max-size-buffers=$q '!' kmssink
done

echo
echo "=== 单 queue 也扫一下 ==="
for q in 1 2 3 4 6; do
    try "queue($q) ! kmssink" \
        v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=$q '!' kmssink
done

echo
echo "=== 双 queue + 缩放到屏幕原生 1440x900 ==="
try "queue(4) ! videoscale 1440x900 ! queue(4) ! kmssink" \
    v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=4 '!' videoscale \
    '!' video/x-raw,width=1440,height=900 '!' queue max-size-buffers=4 '!' kmssink

echo
echo "=== 顺带看一下色域修复在这个通路上的代价 (videobalance 做范围扩展的替代方案) ==="
try "queue(4) ! videoconvert ! queue(4) ! kmssink (重复基准)" \
    v4l2src device=$DEV num-buffers=$N '!' $V '!' queue max-size-buffers=4 '!' videoconvert '!' queue max-size-buffers=4 '!' kmssink

echo
echo "=== 上限参照 ==="
try "采集上限 fakesink" v4l2src device=$DEV num-buffers=$N '!' $V '!' fakesink
