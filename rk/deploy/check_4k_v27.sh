#!/bin/sh
# V27 上板验证: 4K25 是否出帧 + 几何寄存器 + 链路速率档
D=/root/rk/deploy
echo "=== 关键寄存器 ==="
python3 $D/fpga_cfg.py dump 2>&1 | grep -Ei "RES_MODE|FRAME_CNT|HEARTBEAT|VER_|0xD0|0xD1|0xD2|0xD3|0xD4|0xD5|CAM_|0xE0"
echo ""
echo "=== 帧率测量 (5s) ==="
A=$(python3 $D/fpga_cfg.py get FRAME_CNT 2>/dev/null | tr -dc '0-9')
sleep 5
B=$(python3 $D/fpga_cfg.py get FRAME_CNT 2>/dev/null | tr -dc '0-9')
echo "A=$A  B=$B  delta=$((B-A))  => $(( (B-A)/5 )) fps"
echo ""
echo "=== V4L2 节点 ==="
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | head -8
echo ""
echo "=== media2 链路 ==="
media-ctl -d /dev/media2 -p 2>&1 | grep -E "^\s+\[|entity|device" | head -30
