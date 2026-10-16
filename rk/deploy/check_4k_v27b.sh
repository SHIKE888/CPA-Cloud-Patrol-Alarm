#!/bin/sh
# V27 上板验证 2: 帧率 + RES_MODE + 行组数 + RK 侧设 4K
D=/root/rk/deploy
echo "=== 寄存器全量 ==="
python3 $D/fpga_cfg.py dump 2>&1
echo ""
echo "=== 帧率 (6s) ==="
A=$(python3 $D/fpga_cfg.py dump 2>&1 | grep -o '帧计数 = [0-9]*' | tr -dc '0-9')
sleep 6
B=$(python3 $D/fpga_cfg.py dump 2>&1 | grep -o '帧计数 = [0-9]*' | tr -dc '0-9')
echo "A=$A B=$B delta=$((B-A))"
awk "BEGIN{printf \"=> %.2f fps\n\", ($B-$A)/6}"
echo ""
echo "=== 把 RK 侧设成 4K ==="
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]' 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":1[fmt:YUYV8_2X8/3840x2160]' 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]' 2>&1
sleep 1
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16 2>&1
echo "--- 设置后 ---"
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | head -6
echo ""
echo "=== 抓 10 帧看是否顺畅 ==="
timeout 8 v4l2-ctl -d /dev/video22 --stream-mmap --stream-count=10 2>&1 | tail -14
