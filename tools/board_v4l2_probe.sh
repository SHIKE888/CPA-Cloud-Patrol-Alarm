#!/bin/sh
echo "=== 再等 15 秒看快照 ==="
sleep 15
curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/n1.jpg
echo "  $(stat -c %s /tmp/n1.jpg) 字节"

echo "=== gst / python 进程 ==="
pgrep -af 'gst-launch|mipi_webstream' | cut -c1-100

echo "=== 直接测 V4L2 (需先停 web 释放设备) ==="
systemctl stop mipi-webstream
sleep 2
timeout 12 v4l2-ctl --device /dev/video22 \
    --set-fmt-video=width=1920,height=1080,pixelformat=NV16 \
    --stream-mmap --stream-count=5 2>&1 | tail -8
echo "  exit=$?"

echo "=== media 通路当前格式 ==="
media-ctl -d /dev/media2 -p 2>&1 | grep -E 'entity|pad0|fmt' | head -25
echo "=== 重启 web ==="
systemctl start mipi-webstream
