#!/bin/sh
# 0xA9/0xAA = CFG_VER (低字节在前)
a=$(i2cget -y 9 0x40 0xa9)
b=$(i2cget -y 9 0x40 0xaa)
echo "CFG_VER 低=$a 高=$b   (0x4703 => 低=0x03 高=0x47)"
echo "0xDB = $(i2cget -y 9 0x40 0xdb)"
echo "--- 再读一遍 E1..E9, 间隔 2 秒 ---"
i=1
while [ $i -le 9 ]; do
    r=$(printf '0x%02x' $((0xE0 + i)))
    printf 'E%d=%s ' "$i" "$(i2cget -y 9 0x40 $r)"
    i=$((i + 1))
done
echo
sleep 2
i=1
while [ $i -le 9 ]; do
    r=$(printf '0x%02x' $((0xE0 + i)))
    printf 'E%d=%s ' "$i" "$(i2cget -y 9 0x40 $r)"
    i=$((i + 1))
done
echo
echo "--- 快照 ---"
curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/c.jpg
ls -l /tmp/c.jpg
