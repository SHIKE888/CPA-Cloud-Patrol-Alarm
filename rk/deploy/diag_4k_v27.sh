#!/bin/sh
# 为什么 4K 抓不到帧
echo "=== 帧计数 5s 内变化 ==="
A=$(python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -o '帧计数 = [0-9]*' | tr -dc '0-9')
sleep 5
B=$(python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -o '帧计数 = [0-9]*' | tr -dc '0-9')
echo "A=$A B=$B delta=$((B-A))"

echo ""
echo "=== dmesg 全部尾部 40 行 ==="
dmesg | tail -40

echo ""
echo "=== 再抓一次, 看详细错误 ==="
rm -f /tmp/f4k.raw
timeout 15 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=3 --stream-to=/tmp/f4k.raw --verbose 2>&1 | tail -25
echo "size=$(stat -c %s /tmp/f4k.raw 2>/dev/null || echo 0)"

echo ""
echo "=== media2 链路现状 ==="
media-ctl -d /dev/media2 -p 2>&1 | grep -B1 -A3 -E "entity 63|entity 58|entity 45" | head -30

echo ""
echo "=== 各 pad 当前 fmt ==="
for m in '"m02_back_FPGA-MIPI 9-001a"'; do :; done
v4l2-ctl -d /dev/v4l-subdev4 --get-subdev-fmt 2>&1 | head -20
