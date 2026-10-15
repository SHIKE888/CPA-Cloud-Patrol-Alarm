#!/bin/bash
# 为"内核编译说明"补齐事实: 构建命令 / boot.img 打包 / 体积 / 现状
SDK="$HOME/mlk-sdk-3576-v1.1.0"
K="$SDK/kernel-6.1"

echo "=== 1. build.sh 完整命令列表 ==="
"$SDK/build.sh" --help 2>&1 | sed -n '/Command/,/^$/p' | head -40

echo
echo "=== 2. boot.img 打包配方 ==="
echo "--- kernel-6.1/boot.its ---"
cat "$K/boot.its" 2>/dev/null | head -50
echo "--- resource.img / *.dtb 现状 ---"
ls -la "$K/resource.img" "$K/arch/arm64/boot/Image.lz4" "$K/arch/arm64/boot/dts/rockchip/mlk-afh03-rk3576-linux.dtb" 2>/dev/null | head
echo "--- 有没有 mkimage/fit 工具 ---"
ls "$SDK/u-boot/tools/mkimage" "$SDK/tools/mkimage" 2>/dev/null

echo
echo "=== 3. 体积统计 (评估全树源码备份大小) ==="
du -sh "$K" 2>/dev/null
echo "--- 排除编译产物后的源码体积(前 40 个大目录) ---"
find "$K" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -5 >/dev/null
mkdir -p /tmp/duprobe && rm -rf /tmp/duprobe/* 2>/dev/null
tar --exclude='*.o' --exclude='*.a' --exclude='*.cmd' --exclude='*.ko' --exclude='*.mod*' \
    --exclude='.tmp*' --exclude='modules.*' -cf /dev/null "$K" 2>/dev/null && echo "(tar 试算完成)"
du -sh --exclude='*.o' --exclude='*.a' --exclude='*.cmd' "$K" 2>/dev/null

echo
echo "=== 4. .config 关键项再确认 ==="
grep -E 'CONFIG_VIDEO_MILIANKE_FPGA_VIRTUAL|CONFIG_LOCALVERSION|CONFIG_DEBUG_INFO=|CONFIG_KALLSYMS' "$K/.config"

echo
echo "=== 5. 内核 .config 对应的 defconfig 片段 ==="
ls "$SDK/device/rockchip/rk3576/" | grep -i mlk

echo
echo "=== 6. 备份目录现状 ==="
ls -la "$HOME/kernel-backup" 2>/dev/null || echo "(尚无 kernel-backup 目录)"

echo
echo "=== 7. 上次编译的会话日志(确认编译命令) ==="
ls -t "$SDK/output/sessions" 2>/dev/null | head -5
LAST=$(ls -t "$SDK/output/sessions" 2>/dev/null | head -1)
if [ -n "$LAST" ]; then
    ls "$SDK/output/sessions/$LAST" 2>/dev/null | head -10
    grep -h -o -E '(make|build\.sh)[^"]*kernel[^"]*' "$SDK/output/sessions/$LAST"/*.log 2>/dev/null | head -10
fi
