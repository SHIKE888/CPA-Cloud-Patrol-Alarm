#!/bin/sh
echo "=== 等 25 秒 ==="
sleep 25
for t in 1 2 3; do
    curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/p$t.jpg
    printf '  快照%d: %s 字节  %s\n' "$t" "$(stat -c %s /tmp/p$t.jpg)" \
        "$(md5sum /tmp/p$t.jpg | cut -d' ' -f1)"
    sleep 1
done
echo "--- E 系列 ---"
i=1
while [ $i -le 9 ]; do
    printf '%s ' "$(i2cget -y 9 0x40 $(printf '0x%02x' $((0xE0 + i))))"
    i=$((i + 1))
done
echo
sleep 2
i=1
while [ $i -le 9 ]; do
    printf '%s ' "$(i2cget -y 9 0x40 $(printf '0x%02x' $((0xE0 + i))))"
    i=$((i + 1))
done
echo
echo "0xDB=$(i2cget -y 9 0x40 0xdb)  0xE0=$(i2cget -y 9 0x40 0xe0)"
echo "--- 采集进程 ---"
ps aux | grep -E 'gst-launch|start_web|mipi_web' | grep -v grep | cut -c1-100
