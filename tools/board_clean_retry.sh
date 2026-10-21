#!/bin/sh
echo "=== 干净重启 web, 独占设备 ==="
systemctl restart mipi-webstream
sleep 22
echo "--- 快照 3 帧 ---"
i=1
while [ $i -le 3 ]; do
    curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/g$i.jpg
    printf '  %s  %s 字节\n' "$(md5sum /tmp/g$i.jpg | cut -d' ' -f1)" \
                            "$(stat -c %s /tmp/g$i.jpg)"
    sleep 1
    i=$((i + 1))
done
echo "--- 状态 JSON ---"
curl -s --max-time 6 http://localhost:9012/api/status \
  | tr ',' '\n' | grep -E 'width|height|"fps|locked|frames|err' | head -12
echo "--- dmesg 最近 30 行里 MIPI ERR 计数 ---"
dmesg | tail -30 | grep -c 'MIPI_CSI2 ERR'
echo "--- E 系列 ---"
i=1
while [ $i -le 9 ]; do
    printf '%s ' "$(i2cget -y 9 0x40 $(printf '0x%02x' $((0xE0 + i))))"
    i=$((i + 1))
done
echo
