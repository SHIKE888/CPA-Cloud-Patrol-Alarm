#!/bin/sh
# 0xB8..0xBB = FRAME_CNT (32 位小端, FPGA 侧已接收帧数)
# 这个计数器完全独立于 web 缓存, 能判断 FPGA 到底还在不在出新帧
fc() {
    b0=$(i2cget -y 9 0x40 0xb8); b1=$(i2cget -y 9 0x40 0xb9)
    b2=$(i2cget -y 9 0x40 0xba); b3=$(i2cget -y 9 0x40 0xbb)
    echo "$((b3 * 16777216 + b2 * 65536 + b1 * 256 + b0))"
}
echo "--- FRAME_CNT 连续取样 (每 2 秒) ---"
i=1
while [ $i -le 4 ]; do
    printf '  t%d  FRAME_CNT=%s\n' "$i" "$(fc)"
    sleep 2
    i=$((i + 1))
done
echo "0xDB = $(i2cget -y 9 0x40 0xdb)"
echo "--- web 侧快照 md5 ---"
curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/z1.jpg
sleep 1
curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/z2.jpg
md5sum /tmp/z1.jpg /tmp/z2.jpg
