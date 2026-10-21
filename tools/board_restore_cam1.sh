#!/bin/sh
echo "=== 1. 写 0xDB = 0x05 (cam1 + mark_en) ==="
i2cset -y 9 0x40 0xdb 0x05
echo "  回读 0xDB = $(i2cget -y 9 0x40 0xdb)"
sleep 2

echo "=== 2. E 系列 (写后立刻, 看 RX 复位窗有没有把时钟带起来) ==="
dump() {
    i=1
    while [ $i -le 9 ]; do
        printf '%s ' "$(i2cget -y 9 0x40 $(printf '0x%02x' $((0xE0 + i))))"
        i=$((i + 1))
    done
    echo
}
printf '        E1   E2   E3   E4   E5   E6   E7   E8   E9\n'
printf '  t1:   '; dump
sleep 2
printf '  t2:   '; dump

echo "=== 3. 重启采集 (换源后 V4L2 必须重开) ==="
systemctl restart mipi-webstream
sleep 14

echo "=== 4. 重启后 E 系列 ==="
printf '  t1:   '; dump
sleep 2
printf '  t2:   '; dump

echo "=== 5. 3 帧快照 md5 (必须不一样才说明画面在动) ==="
i=1
while [ $i -le 3 ]; do
    curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/w$i.jpg
    printf '  %s  %s 字节\n' "$(md5sum /tmp/w$i.jpg | cut -d' ' -f1)" \
                            "$(stat -c %s /tmp/w$i.jpg)"
    sleep 1
    i=$((i + 1))
done
echo "0xDB = $(i2cget -y 9 0x40 0xdb)"
