#!/bin/bash
# diag_stream.sh —— 诊断 /dev/video22 采集失效原因

echo "=== dmesg (milianke / rkcif / fpga) ==="
dmesg 2>/dev/null | grep -iE 'milianke|rkcif|fpga|mipi' | tail -25

echo
echo "=== 视频节点 ==="
for d in /sys/class/video4linux/video*; do
    n=$(basename "$d")
    printf '  %-10s %s\n' "$n" "$(cat "$d/name" 2>/dev/null)"
done

echo
echo "=== /dev/video22 支持的格式 ==="
v4l2-ctl -d /dev/video22 --list-formats-ext 2>&1 | head -30

echo
echo "=== 尝试采集 5 帧 (v4l2-ctl) ==="
v4l2-ctl -d /dev/video22 \
    --set-fmt-video=width=1920,height=1080,pixelformat=NV16 \
    --stream-mmap --stream-count=5 --stream-to=/tmp/t.bin 2>&1 | tail -8
echo "  输出文件: $(ls -l /tmp/t.bin 2>/dev/null || echo '（没有产生）')"

echo
echo "=== media-ctl 拓扑 (CSI3 相关) ==="
which media-ctl >/dev/null 2>&1 && media-ctl -p 2>/dev/null | grep -A3 -iE 'mipi3|dphy3|rkcif' | head -40 \
    || echo "  media-ctl 不可用"

echo
echo "=== rkcif 摄像头状态 ==="
cat /sys/kernel/debug/rkcif*/* 2>/dev/null | head -20 || echo "  无 rkcif debugfs"
