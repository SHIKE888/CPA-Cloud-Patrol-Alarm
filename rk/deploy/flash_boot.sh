#!/bin/bash
# 在 RK3576 板上刷 boot 分区 (非交互, 供无人值守调用)
#
# 用法: flash_boot.sh <img> --yes [--no-reboot]
#
# 安全措施:
#   - 校验镜像存在、大小不超过分区
#   - 打印分区/镜像大小与 md5、当前内核版本
#   - 必须显式传 --yes 才动手 (避免误触)
#
# 回滚: 用 rk/backup/boot.dump-20261015.img (64MB 整分区 dump) 同样方式刷回
set -e

IMG="$1"
CONFIRM="$2"
NOREB="$3"
PART=/dev/disk/by-partlabel/boot

if [ -z "$IMG" ]; then
    echo "用法: $0 <img> --yes [--no-reboot]"
    exit 1
fi
[ -f "$IMG" ] || { echo "!! 找不到镜像: $IMG"; exit 1; }
[ "$CONFIRM" = "--yes" ] || { echo "!! 未确认, 需要第二个参数 --yes"; exit 1; }
[ -b "$PART" ] || { echo "!! 分区不存在: $PART"; exit 1; }

PSIZE=$(blockdev --getsize64 "$PART")
ISIZE=$(stat -c %s "$IMG")

echo "=== 刷写前 ==="
echo "  当前内核  : $(cat /proc/version)"
echo "  目标分区  : $PART  ($PSIZE B)"
echo "  待刷镜像  : $IMG  ($ISIZE B)"
echo "  镜像 md5  : $(md5sum "$IMG" | cut -d' ' -f1)"

if [ "$ISIZE" -gt "$PSIZE" ]; then
    echo "!! 镜像 ($ISIZE) 大于分区 ($PSIZE), 拒绝刷写"
    exit 1
fi

echo
echo "=== 刷写中 (dd conv=fsync) ==="
dd if="$IMG" of="$PART" conv=fsync
sync
echo "  写入完成"
echo "  回读前 8MB md5: $(dd if="$PART" bs=1M count=8 2>/dev/null | md5sum | cut -d' ' -f1)"
echo "  镜像前 8MB md5: $(head -c 8388608 "$IMG" | md5sum | cut -d' ' -f1)"

if [ "$NOREB" = "--no-reboot" ]; then
    echo
    echo "已跳过重启 (--no-reboot)。手动生效请执行 reboot"
else
    echo
    echo "3 秒后重启..."
    sleep 3
    reboot
fi
