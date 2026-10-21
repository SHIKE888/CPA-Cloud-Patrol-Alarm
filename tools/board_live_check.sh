#!/bin/sh
echo "--- 进程 ---"
systemctl show mipi-webstream -p MainPID -p ActiveEnterTimestamp --value
ps -o pid,etime,cmd -p "$(systemctl show mipi-webstream -p MainPID --value)" 2>/dev/null | tail -1 | cut -c1-90
echo "--- 连抓 3 帧看 md5 是否变化 (不变 = 冻结) ---"
i=1
while [ $i -le 3 ]; do
    curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/m$i.jpg
    printf '  %s  %s 字节\n' "$(md5sum /tmp/m$i.jpg | cut -d' ' -f1)" "$(stat -c %s /tmp/m$i.jpg)"
    sleep 1
    i=$((i + 1))
done
echo "  0xDB = $(i2cget -y 9 0x40 0xdb)"
