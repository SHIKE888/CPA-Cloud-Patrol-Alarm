#!/bin/bash
# V27: 把修好的 milianke_mipi.c 覆盖进内核树并增量编译 boot.img
set -e
SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
CC=$SDK/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-
DRV=$SDK/kernel-6.1/drivers/media/i2c/milianke_mipi.c

BK=/home/uisrc/kernel-backup/$(date +%Y%m%d-%H%M%S)-v27
mkdir -p "$BK/files"
cp -a "$DRV" "$BK/files/milianke_mipi.c.before-v27"
md5sum "$DRV" > "$BK/files/MANIFEST.md5"
[ -f $SDK/kernel-6.1/.config ] && cp -a $SDK/kernel-6.1/.config "$BK/.config.before"
echo "### 备份目录: $BK"
cat "$BK/files/MANIFEST.md5"

echo ""
echo "### 覆盖驱动"
cp /tmp/milianke_mipi.ref.c "$DRV"
diff -u "$BK/files/milianke_mipi.c.before-v27" "$DRV" > "$BK/milianke_mipi.c.patch" || true
echo "patch 行数: $(wc -l < $BK/milianke_mipi.c.patch)"
md5sum "$DRV"

echo ""
echo "### 确认驱动是内置 (=y)"
grep -n "MILIANKE" $SDK/kernel-6.1/.config || true

echo ""
echo "### 编译开始 $(date +%H:%M:%S)"
make -C $SDK/kernel/ -j17 CROSS_COMPILE=$CC ARCH=arm64 mlk-afh03-rk3576-linux.img 2>&1 | tail -35
echo "### 编译结束 $(date +%H:%M:%S)"

echo ""
echo "### 产物"
ls -l $SDK/kernel-6.1/boot.img $SDK/kernel-6.1/arch/arm64/boot/Image $SDK/kernel-6.1/resource.img
md5sum $SDK/kernel-6.1/boot.img
echo "### 基线对比 (旧 #7 = 7de2852e... 分区/0deb3ac7... boot.img)"
