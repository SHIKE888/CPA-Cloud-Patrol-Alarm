#!/bin/sh
# V27 最终验证: 驱动注册 -> 4K 通路 -> 抓帧
echo "=== 1) 驱动注册 dmesg ==="
dmesg | grep -iE "milianke" | head -10

echo ""
echo "=== 2) FPGA 侧寄存器 ==="
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | tail -6

echo ""
echo "=== 3) 停 web, 设 4K 通路 ==="
pkill -f mipi_webstream.py 2>/dev/null && echo "  已停 web" || echo "  web 未在运行"
sleep 1
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' && echo "  sensor:0 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]' && echo "  dphy3:0 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]' && echo "  csi2:0 ok"
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16
v4l2-ctl -d /dev/video22 --get-fmt-video | head -4

echo ""
echo "=== 4) dmesg: dummy buffer 是否算对了 ==="
dmesg | grep -iE "dummy|alloc_buffer|Cannot" | tail -6

echo ""
echo "=== 5) 抓 10 帧 ==="
rm -f /tmp/f4k.raw
timeout 20 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=10 --stream-to=/tmp/f4k.raw 2>&1 | tail -12
SZ=$(stat -c %s /tmp/f4k.raw 2>/dev/null || echo 0)
echo "  抓到 $SZ 字节 (10 帧 4K NV16 应为 124416000)"

echo ""
echo "=== 6) 转 PNG 便于看画面 ==="
python3 - <<'PYEOF'
import os
p='/tmp/f4k.raw'; W,H=3840,2160
sz=os.path.getsize(p); print("raw=%d  期望单帧=%d  帧数=%.2f" % (sz, W*H*3//2, sz/(W*H*3/2)))
if sz < W*H: print("数据不足"); raise SystemExit
d=open(p,'rb').read()
try:
    from PIL import Image
    im=Image.frombytes('L',(W,H),d[:W*H])
    im.resize((1280,720)).save('/tmp/f4k_y.png')
    print("已存 /tmp/f4k_y.png   Y min/max/mean=%d/%d/%.1f" % (min(d[:W*H]),max(d[:W*H]),sum(d[:W*H])/(W*H)))
    uv=d[W*H:W*H+W*H//2]
    print("UV 平面 min/max/mean=%d/%d/%.1f" % (min(uv),max(uv),sum(uv)/len(uv)))
except Exception as e:
    print("PIL:",e)
PYEOF
