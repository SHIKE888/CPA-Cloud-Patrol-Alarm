#!/bin/sh
# V28 上板验证: packer FIFO 门限修复后 4K 是否能抓到帧
echo "=== 0) FPGA 侧 ==="
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -E "帧计数|0xE0|0xD4|0xD5"
echo -n "  0xE0(RES_MODE) = "; python3 /root/rk/deploy/fpga_cfg.py get 0xE0 2>&1 | tail -1
echo -n "  0xD4 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD4 2>&1 | tail -1
echo -n "  0xD5 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD5 2>&1 | tail -1

echo ""
echo "=== 1) 停 web ==="
pkill -f mipi_webstream.py 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 1

echo ""
echo "=== 2) 设 4K 通路 ==="
dmesg -c >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' && echo "  sensor:0 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]' && echo "  dphy3:0 ok"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]' && echo "  csi2:0 ok"
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16
v4l2-ctl -d /dev/video22 --get-fmt-video | head -4

echo ""
echo "=== 3) 抓 3 帧 (期望 37324800 字节) ==="
rm -f /tmp/f4k.raw
timeout 15 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=3 --stream-to=/tmp/f4k.raw 2>&1 | tail -10
SZ=$(stat -c %s /tmp/f4k.raw 2>/dev/null || echo 0)
echo "  >>> 抓到 $SZ 字节"

echo ""
echo "=== 4) dmesg ==="
dmesg 2>&1 | grep -iE "rkcif|milianke|dphy" | tail -10

echo ""
echo "=== 5) 存 PNG 看画面 ==="
python3 - <<'PYEOF'
import os
p='/tmp/f4k.raw'; W,H=3840,2160
sz=os.path.getsize(p); print("raw=%d  单帧=%d  帧数=%.2f" % (sz, W*H*2, sz/(W*H*2)))
if sz < W*H: print("数据不足, 无画面可存"); raise SystemExit
d=open(p,'rb').read()
try:
    from PIL import Image
    y=d[:W*H]
    Image.frombytes('L',(W,H),y).resize((1280,720)).save('/tmp/f4k_y.png')
    print("已存 /tmp/f4k_y.png   Y min/max/mean=%d/%d/%.1f" % (min(y),max(y),sum(y)/(W*H)))
    uv=d[W*H:W*H+W*H//2]
    print("UV min/max/mean=%d/%d/%.1f" % (min(uv),max(uv),sum(uv)/len(uv)))
    # 水平方向每 3840/16 列取样, 看行内是否单调(有无重复/断裂)
    row=y[1000*W:1001*W]
    print("第1000行 每240列取样:", [row[i*240] for i in range(16)])
except Exception as e:
    print("PIL:", e)
PYEOF
