#!/bin/sh
# 强制格式化 SD 卡并挂载 (分区表是 FAT32 但引导扇区全 0, 实际没有文件系统)
echo "=== 当前状态 ==="
mountpoint -q /mnt/sd && echo "已挂载" || echo "未挂载"
blkid /dev/mmcblk1p1 || echo "blkid 无输出"

echo "=== 强制格式化 ext4 ==="
umount /mnt/sd 2>/dev/null
mkfs.ext4 -F -L SDLOG /dev/mmcblk1p1 2>&1 | tail -3

echo "=== 挂载 ==="
mkdir -p /mnt/sd
mount LABEL=SDLOG /mnt/sd
mkdir -p /mnt/sd/log
mountpoint /mnt/sd
df -h /mnt/sd | tail -1

echo "=== 写一条测试致命日志 ==="
logger -p kern.crit "SD_LOG_TEST: 这是一条测试用的致命级别日志"
sleep 2
ls -lh /mnt/sd/log/ 2>/dev/null
tail -2 /mnt/sd/log/kernel-fatal.log 2>/dev/null
