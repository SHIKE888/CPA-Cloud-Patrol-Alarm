#!/bin/sh
P=$(pgrep -f cloud_agent.py | head -1)
echo "=== agent pid=$P 线程数=$(ls /proc/$P/task 2>/dev/null | wc -l) ==="
cat /proc/$P/status 2>/dev/null | grep -E 'Threads|VmRSS|VmHWM'

echo "=== 环形缓存 /mnt/sd/csi_ring ==="
N=$(ls /mnt/sd/csi_ring 2>/dev/null | wc -l)
echo "  文件数 = $N"
ls -lt /mnt/sd/csi_ring 2>/dev/null | head -5

echo "=== 待上传 /mnt/sd/csi_clips ==="
ls -lt /mnt/sd/csi_clips 2>/dev/null | head -5
echo "  文件数 = $(ls /mnt/sd/csi_clips 2>/dev/null | wc -l)"

echo "=== 隔 5 秒再看环形缓存是否在增长 ==="
sleep 5
echo "  文件数 = $(ls /mnt/sd/csi_ring 2>/dev/null | wc -l)"
ls -lt /mnt/sd/csi_ring 2>/dev/null | head -3

echo "=== 线程名 (看 ring/clipretry 在不在) ==="
for t in /proc/$P/task/*; do
    echo "  $(cat $t/comm 2>/dev/null)"
done | sort | uniq -c | sort -rn | head -10

echo "=== 磁盘占用 ==="
du -sh /mnt/sd/csi_ring /mnt/sd/csi_clips 2>/dev/null
df -h /mnt/sd | tail -1
