#!/bin/sh
systemctl restart mipi-webstream
sleep 10
echo "--- 快照 ---"
curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/a.jpg
ls -l /tmp/a.jpg
echo "--- 诊断 E1..E9 (各读两次, 看是否在涨) ---"
i=1
while [ $i -le 9 ]; do
    a=$(i2cget -y 9 0x40 $(printf '0x%02x' $((0xE0 + i))) 2>/dev/null)
    b=$(i2cget -y 9 0x40 $(printf '0x%02x' $((0xE0 + i))) 2>/dev/null)
    printf 'E%d = %s -> %s\n' "$i" "$a" "$b"
    i=$((i + 1))
done
echo "0xDB = $(i2cget -y 9 0x40 0xdb)"
