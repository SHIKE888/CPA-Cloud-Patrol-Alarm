#!/bin/bash
# 探查 mlk-sdk-3576-v1.1.0 的结构、构建入口、内核配置与驱动现状
SDK="$HOME/mlk-sdk-3576-v1.1.0"
K="$SDK/kernel-6.1"

echo "=== 1. SDK 顶层 ==="
ls -la "$SDK" | head -40

echo
echo "=== 2. 内核树确认 ==="
ls "$K" 2>/dev/null | head -30
echo "--- kernel version ---"
make -s -C "$K" kernelversion 2>/dev/null || grep -m1 -E '^(VERSION|PATCHLEVEL|SUBLEVEL)' "$K/Makefile" 2>/dev/null

echo
echo "=== 3. 是否已编译过 (产物时间) ==="
ls -la "$K/arch/arm64/boot/Image" "$K/arch/arm64/boot/Image.lz4" "$K/vmlinux" "$K/.config" 2>/dev/null
echo "--- output/ ---"
ls -la "$SDK/output" 2>/dev/null | head -20
ls -la "$SDK/output/firmware" 2>/dev/null | head -20

echo
echo "=== 4. 构建入口 ==="
ls "$SDK"/*.sh "$SDK"/*.mk "$SDK"/Makefile 2>/dev/null
echo "--- device 配置 ---"
ls "$SDK/device/rockchip/rk3576" 2>/dev/null | head -40
echo "--- 当前 link 到哪个 defconfig ---"
ls -la "$SDK/device/rockchip/.current" "$SDK/device/rockchip/.BoardConfig.mk" 2>/dev/null

echo
echo "=== 5. 交叉工具链 ==="
ls -d "$SDK/prebuilts/gcc/linux-x86/aarch64"/* 2>/dev/null | head -10
ls "$SDK/prebuilts/gcc/linux-x86/aarch64"/*/bin/*gcc 2>/dev/null | head -5

echo
echo "=== 6. 驱动文件 milianke / fpga 相关 ==="
find "$K" -maxdepth 6 -type f \( -iname "milianke*" -o -iname "*fpga_virtual*" \) 2>/dev/null | head -20

echo
echo "=== 7. 内核树 git 状态 (是否有本地改动) ==="
if [ -d "$K/.git" ]; then
    git -C "$K" status --short | head -30
    echo "--- 最近提交 ---"
    git -C "$K" log --oneline -5
else
    echo "kernel-6.1 不是 git 仓库"
fi

echo
echo "=== 8. 内核当前 .config 关键项 ==="
if [ -f "$K/.config" ]; then
    grep -E '^CONFIG_(MILIANKE|VIDEO_MILIANKE|I2C_MUX|VIDEO_ROCKCHIP_CIF|VIDEO_ROCKCHIP_ISP)' "$K/.config" | head -20
else
    echo "无 $K/.config (未 configure)"
fi

echo
echo "=== 9. dts 里 fpga 节点 ==="
grep -rl "milianke" "$K/arch/arm64/boot/dts/rockchip" 2>/dev/null | head -10
