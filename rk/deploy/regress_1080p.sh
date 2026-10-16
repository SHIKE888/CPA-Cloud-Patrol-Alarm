#!/bin/sh
# 回归检查: 切回 1080p 看能否抓帧 (确认驱动改动没破坏原功能)
echo "=== 0) 清 dmesg ==="
dmesg -c >/dev/null 2>&1

echo "=== 1) FPGA 切回 1080p (RES_MODE=0) ==="
python3 /root/rk/deploy/fpga_cfg.py set RES_MODE 0 2>&1
sleep 2
python3 /root/rk/deploy/fpga_cfg.py get RES_MODE 2>&1
echo "  行组数 0xD4/0xD5:"
python3 /root/rk/deploy/fpga_cfg.py get 0xD4 2>&1
python3 /root/rk/deploy/fpga_cfg.py get 0xD5 2>&1

echo ""
echo "=== 2) 设 1080p 通路 ==="
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/1920x1080]' && echo "  sensor:0 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/1920x1080]' && echo "  dphy3:0 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/1920x1080]' && echo "  csi2:0 ok"
v4l2-ctl -d /dev/video22 --set-fmt-video=width=1920,height=1080,pixelformat=NV16
v4l2-ctl -d /dev/video22 --get-fmt-video | head -4

echo ""
echo "=== 3) 抓 5 帧 ==="
rm -f /tmp/f1080.raw
timeout 12 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=5 --stream-to=/tmp/f1080.raw 2>&1 | tail -8
echo "  size=$(stat -c %s /tmp/f1080.raw 2>/dev/null || echo 0)  (5 帧 NV16 = 15552000)"
dmesg 2>&1 | grep -iE "rkcif|milianke|dphy" | tail -12

echo ""
echo "=== 4) 再切回 4K 试一次 (排除启动顺序) ==="
python3 /root/rk/deploy/fpga_cfg.py set RES_MODE 2 2>&1
sleep 3
python3 /root/rk/deploy/fpga_cfg.py get RES_MODE 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]'
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]'
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]'
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null
rm -f /tmp/f4k.raw
timeout 12 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=3 --stream-to=/tmp/f4k.raw 2>&1 | tail -6
echo "  4K size=$(stat -c %s /tmp/f4k.raw 2>/dev/null || echo 0)"
