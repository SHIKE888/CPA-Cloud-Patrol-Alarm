#!/bin/sh
# V27 上板验证 5: 干净顺序 + 重试 -> 抓 4K 帧
set -x
echo "=== 1) 先彻底停流 ==="
v4l2-ctl -d /dev/video22 --streamoff 2>&1
pkill -f mipi_webstream.py 2>&1
sleep 2

echo "=== 2) 设链路 + 节点格式 ==="
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]'
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]'
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]'
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16
sleep 1
v4l2-ctl -d /dev/video22 --get-fmt-video | head -4

echo "=== 3) 抓帧, 最多试 6 次 ==="
n=0
while [ $n -lt 6 ]; do
  n=$((n+1))
  echo "--- 第 $n 次 ---"
  rm -f /tmp/f4k.raw
  if timeout 12 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=3 --stream-to=/tmp/f4k.raw 2>&1 | tail -4; then :; fi
  SZ=$(stat -c %s /tmp/f4k.raw 2>/dev/null || echo 0)
  echo "  抓到 $SZ 字节"
  if [ "$SZ" -gt 1000000 ]; then echo "  >>> 成功"; break; fi
  sleep 1
done
ls -l /tmp/f4k.raw
