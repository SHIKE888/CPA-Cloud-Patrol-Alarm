#!/bin/bash
# ============================================================================
# 内核回滚 (在虚拟机 uisrc@192.168.65.128 上运行)
#   用法:  tools\vmsh.ps1 -File tools\vm_restore_kernel.sh -ScriptArgs "/home/uisrc/kernel-backup/<时间戳> --file-only"
#   不传 --file-only 则连整棵树一起回滚(需全量重编)
# ============================================================================
set -e

BK="${1:?用法: vm_restore_kernel.sh <备份目录> [--file-only]}"
MODE="$2"
SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
K="$SDK/kernel-6.1"
DRV="$K/drivers/media/i2c/milianke_mipi.c"
STOCK_MD5=15931acbe1f7f12332101a33ed9b2d20

[ -d "$BK" ] || { echo "备份目录不存在: $BK"; exit 1; }

echo "== 1. 校验备份完整性 =="
( cd "$BK/files" && md5sum -c MANIFEST.md5 )

echo
echo "== 2. 单文件回滚 (驱动) =="
cp -a "$BK/files/milianke_mipi.c.orig" "$DRV"
NOW_MD5=$(md5sum "$DRV" | cut -d' ' -f1)
echo "现在: $NOW_MD5   期望: $STOCK_MD5"
[ "$NOW_MD5" = "$STOCK_MD5" ] && echo "驱动已回到 stock ✓" || { echo "md5 不符, 中止"; exit 1; }

if [ "$MODE" = "--file-only" ]; then
    echo
    echo "仅回滚单文件完成。要生效需重编:"
    echo "  make -C $SDK/kernel/ -j17 CROSS_COMPILE=$SDK/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu- ARCH=arm64 mlk-afh03-rk3576-linux.img"
    exit 0
fi

echo
echo "== 3. 全树回滚 =="
[ -f "$BK/kernel-6.1-src.tgz" ] || { echo "缺少 kernel-6.1-src.tgz, 无法全树回滚"; exit 1; }
sha256sum -c "$BK/kernel-6.1-src.tgz.sha256"

STAMP=$(date +%Y%m%d-%H%M%S)
mv "$K" "${K}.broken-$STAMP"
echo "旧树已移到: ${K}.broken-$STAMP"
tar -xzf "$BK/kernel-6.1-src.tgz" -C "$SDK"
echo "已从备份解开新树(无编译产物, 需全量重编)"
ls -la "$K/boot.img" 2>/dev/null || echo "(新树里没有 boot.img, 属正常)"
