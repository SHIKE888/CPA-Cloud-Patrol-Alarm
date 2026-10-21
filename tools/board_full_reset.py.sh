#!/bin/sh
systemctl stop mipi-webstream
sleep 2
echo "=== 强制完整复位窗: 写 0xE0=0 (同值也会触发 res_chg) ==="
i2cset -y 9 0x40 0xe0 0
sleep 10
echo "  0xE0=$(i2cget -y 9 0x40 0xe0)  0xDB=$(i2cget -y 9 0x40 0xdb)"
echo "=== 重写 0xDB=0x05 ==="
i2cset -y 9 0x40 0xdb 0x05
echo "  回读 0xDB=$(i2cget -y 9 0x40 0xdb)"
sleep 3
echo "=== cam1 校准状态 ==="
echo "  mipi=$(i2cget -y 9 0x40 0xdd) delay=$(i2cget -y 9 0x40 0xde) bestlen=$(i2cget -y 9 0x40 0xdf)"

echo "=== 直接 v4l2 抓 3 帧 (web 已停) ==="
timeout 15 v4l2-ctl --device /dev/video22 \
    --set-fmt-video=width=1920,height=1080,pixelformat=NV16 \
    --stream-mmap --stream-count=3 > /tmp/v4.out 2>&1
echo "  v4l2-ctl rc=$?"
tail -4 /tmp/v4.out

echo "=== dmesg 最近 CSI 报错 ==="
dmesg | tail -60 | grep -cE 'MIPI_CSI2 ERR' | sed 's/^/  ERR 行数: /'

echo "=== 启动 web ==="
systemctl start mipi-webstream
sleep 18
curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/f1.jpg
echo "  快照: $(stat -c %s /tmp/f1.jpg) 字节"
