#!/bin/sh
# 0x4704 上板验证: 版本 / 0xDB / E 系列两遍 / 3 帧快照 md5
lo=$(i2cget -y 9 0x40 0xa9)
hi=$(i2cget -y 9 0x40 0xaa)
echo "CFG_VER = ${hi#0x}${lo#0x}   (0x4704 = 换源复位RX; 0x4702 = 还没烧新bit)"
echo "0xDB    = $(i2cget -y 9 0x40 0xdb)   (期望 0x05)"

echo "--- E 系列 (间隔 2 秒读两遍, 看谁在涨) ---"
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

echo "--- 3 帧快照 md5 (全同 = 冻结) ---"
i=1
while [ $i -le 3 ]; do
    curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/q$i.jpg
    printf '  %s  %s 字节\n' "$(md5sum /tmp/q$i.jpg | cut -d' ' -f1)" \
                            "$(stat -c %s /tmp/q$i.jpg)"
    sleep 1
    i=$((i + 1))
done
