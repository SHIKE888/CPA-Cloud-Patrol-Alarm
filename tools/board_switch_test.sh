#!/bin/sh
# 决定性测试: cam1 -> cam0(空) -> cam1, 看第二段 cam1 画面是否还能动
snap3() {
    i=1
    while [ $i -le 3 ]; do
        curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/t$i.jpg
        printf '    %s  %s字节\n' "$(md5sum /tmp/t$i.jpg | cut -d' ' -f1)" \
                                "$(stat -c %s /tmp/t$i.jpg)"
        sleep 1
        i=$((i + 1))
    done
}
sel() {
    curl -s --max-time 8 -X POST -H 'Content-Type: application/json' \
         -d "{\"RX_SEL\":$1}" http://localhost:9012/api/fpga \
      | tr ',' '\n' | grep -E '"RX_SEL"|"rx_switched"|"message"' | sed 's/^/    /'
}

echo "=== [A] 基线: cam1 (0xDB=$(i2cget -y 9 0x40 0xdb)) ==="
snap3

echo "=== [B] 切到 cam0 (板上无模组, 预期无画面) ==="
sel 0
echo "    0xDB=$(i2cget -y 9 0x40 0xdb)"
sleep 24
snap3

echo "=== [C] 切回 cam1 —— 关键: 必须自己恢复 ==="
sel 1
echo "    0xDB=$(i2cget -y 9 0x40 0xdb)"
sleep 24
snap3

echo "=== [D] E 系列 (tlast E6 必须在涨) ==="
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
echo "=== 服务 ==="
systemctl is-active mipi-webstream
