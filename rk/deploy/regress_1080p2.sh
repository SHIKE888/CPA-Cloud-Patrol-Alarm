#!/bin/sh
# 回归检查 (修正): 用 0xE0 切模式
echo "=== 1) 切到 1080p (写 0xE0=0) ==="
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 0 2>&1
sleep 3
echo -n "  0xE0 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xE0 2>&1 | tail -1
echo -n "  0xD4 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD4 2>&1 | tail -1
echo -n "  0xD5 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD5 2>&1 | tail -1

echo ""
echo "=== 2) 设 1080p 通路 + 抓 5 帧 ==="
dmesg -c >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/1920x1080]'
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/1920x1080]'
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/1920x1080]'
v4l2-ctl -d /dev/video22 --set-fmt-video=width=1920,height=1080,pixelformat=NV16
rm -f /tmp/f1080.raw
timeout 12 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=5 --stream-to=/tmp/f1080.raw 2>&1 | tail -8
echo "  1080p size=$(stat -c %s /tmp/f1080.raw 2>/dev/null || echo 0)  (5 帧 NV16 = 15552000)"

echo ""
echo "=== 3) 切回 4K (写 0xE0=2) ==="
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 2 2>&1
sleep 3
echo -n "  0xE0 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xE0 2>&1 | tail -1
echo -n "  0xD4 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD4 2>&1 | tail -1
echo -n "  0xD5 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD5 2>&1 | tail -1
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]'
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]'
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]'
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null
rm -f /tmp/f4k.raw
timeout 12 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=3 --stream-to=/tmp/f4k.raw 2>&1 | tail -6
echo "  4K size=$(stat -c %s /tmp/f4k.raw 2>/dev/null || echo 0)"

echo ""
echo "=== 4) 帧计数 ==="
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -E "帧计数"
