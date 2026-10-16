#!/bin/sh
# V27 上板验证 4: 4K 抓帧 ENOMEM 定位
echo "=== CMA / 内存 ==="
grep -iE "CmaTotal|CmaFree|MemFree" /proc/meminfo
echo ""
echo "=== dmesg 最近 rkcif/csi/dphy ==="
dmesg 2>/dev/null | tail -40 | grep -iE "rkcif|csi2|dphy|mipi|alloc|ENOMEM|memory" 
echo "--- 全部尾部 ---"
dmesg 2>/dev/null | tail -12
echo ""
echo "=== 少申请几个 buffer 再试 (2 个) ==="
rm -f /tmp/f4k.raw
timeout 10 v4l2-ctl -d /dev/video22 --stream-mmap=2 --stream-count=3 --stream-to=/tmp/f4k.raw 2>&1 | tail -8
ls -l /tmp/f4k.raw
echo ""
echo "=== 试 1 个 buffer ==="
rm -f /tmp/f4k1.raw
timeout 10 v4l2-ctl -d /dev/video22 --stream-mmap=1 --stream-count=1 --stream-to=/tmp/f4k1.raw 2>&1 | tail -6
ls -l /tmp/f4k1.raw
echo ""
echo "=== 当前 media2 链路 fmt ==="
media-ctl -d /dev/media2 -p 2>&1 | grep -A1 -E "entity 63|entity 58|entity 45|entity 1:" | head -24
