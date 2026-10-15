#!/bin/bash
# 内核/驱动基线探查（只读，不改任何文件）
SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
K=$SDK/kernel-6.1
D=$K/drivers/media/i2c/milianke_mipi.c

echo "=== 主机 ==="
hostname; uname -r; date -Is

echo
echo "=== 驱动文件 ==="
ls -la --time-style=full-iso "$D"
md5sum "$D"
wc -l "$D"

echo
echo "=== boot.img (期望 md5 = 0deb3ac78d3ce5861b847f31d88e9414) ==="
ls -la --time-style=full-iso "$K/boot.img"
md5sum "$K/boot.img"

echo
echo "=== 备份目录 ==="
ls -la /home/uisrc/kernel-backup/ 2>/dev/null || echo "(不存在，尚未备份)"

echo
echo "=== 驱动是否已含颜色空间改动 ==="
grep -n 'V4L2_COLORSPACE_REC709\|V4L2_COLORSPACE_SRGB' "$D" || echo "(都没找到?!)"

echo
echo "=== 分辨率硬编码现状 ==="
grep -n 'DUMMY_WIDTH\|DUMMY_HEIGHT\|DUMMY_FPS\|DUMMY_LINK_FREQ\|DUMMY_PIXEL_RATE' "$D"

echo
echo "=== .o / 编译产物时间 ==="
ls -la --time-style=full-iso "$K/drivers/media/i2c/milianke_mipi.o" 2>/dev/null || echo "(无 .o)"
ls -la --time-style=full-iso "$K/arch/arm64/boot/Image" "$K/resource.img" "$K/zboot.img" 2>/dev/null

echo
echo "=== 关键配置 ==="
grep -E 'CONFIG_VIDEO_MILIANKE_FPGA_VIRTUAL|CONFIG_LOCALVERSION=|CONFIG_DEBUG_INFO=' "$K/.config"

echo
echo "=== 交叉工具链 ==="
"$SDK/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-gcc" --version | head -1

echo
echo "=== 磁盘 ==="
df -h / /home | tail -3

echo
echo "=== 内核源码树 git? ==="
git -C "$K" rev-parse --is-inside-work-tree 2>&1 | head -1
