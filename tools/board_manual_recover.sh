#!/bin/sh
systemctl restart mipi-webstream
sleep 22
i=1
while [ $i -le 3 ]; do
    curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/k$i.jpg
    printf '  %s  %s字节\n' "$(md5sum /tmp/k$i.jpg | cut -d' ' -f1)" \
                            "$(stat -c %s /tmp/k$i.jpg)"
    sleep 1
    i=$((i + 1))
done
echo "0xDB=$(i2cget -y 9 0x40 0xdb)"
