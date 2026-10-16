#!/bin/sh
# V27 上板验证 3: 停 web -> 设 4K -> 抓一帧存 PNG
D=/root/rk/deploy
echo "=== 谁占着 video22 ==="
fuser -v /dev/video22 2>&1
ps aux 2>/dev/null | grep -E "mipi_webstream|python3.*web" | grep -v grep
echo ""
echo "=== 停 web ==="
pkill -f mipi_webstream.py && echo "已停" || echo "没在跑"
sleep 2
echo ""
echo "=== 设整条通路 3840x2160 ==="
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' && echo "  sensor pad0 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]' && echo "  dphy3 pad0 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":1[fmt:YUYV8_2X8/3840x2160]' && echo "  dphy3 pad1 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]' && echo "  csi2 pad0 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":4[fmt:YUYV8_2X8/3840x2160]' && echo "  csi2 pad4 ok"
sleep 1
echo ""
echo "=== video22 设 4K 并抓一帧 ==="
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16 2>&1
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | head -6
echo ""
rm -f /tmp/f4k.raw
timeout 10 v4l2-ctl -d /dev/video22 --stream-mmap --stream-count=3 --stream-to=/tmp/f4k.raw 2>&1 | tail -8
ls -l /tmp/f4k.raw 2>&1
echo ""
echo "=== 存 PNG (Y 平面 -> 灰度, UV 平面 -> 色度) ==="
python3 - <<'PYEOF'
import os, struct
p='/tmp/f4k.raw'
sz=os.path.getsize(p)
W,H=3840,2160
print("raw size=%d  期望 YUV422SP(NV16): %d (3/2*W*H)  " % (sz, W*H*3//2))
if sz < W*H:
    print("数据不足, 退出"); raise SystemExit
d=open(p,'rb').read()
try:
    from PIL import Image
    y=d[:W*H]
    im=Image.frombytes('L',(W,H),y)
    im.resize((960,540)).save('/tmp/f4k_y.png')
    print("Y 平面已存 /tmp/f4k_y.png")
except Exception as e:
    print("PIL 不可用:", e)
# 统计 Y 平面亮度分布
import collections
h=collections.Counter(d[:W*H:97])
print("Y 采样直方图(前10):", sorted(h.items())[:10])
print("Y min/max/mean:", min(d[:W*H]), max(d[:W*H]), sum(d[:W*H])/ (W*H))
PYEOF
