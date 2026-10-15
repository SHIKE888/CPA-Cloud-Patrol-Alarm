#!/bin/bash
SDK="$HOME/mlk-sdk-3576-v1.1.0"
K="$SDK/kernel-6.1"
echo "=== CONFIG_VIDEO_MILIANKE_FPGA_VIRTUAL 从哪来 (决定重跑 defconfig 是否安全) ==="
for f in "$K/arch/arm64/configs/rk3576.config" \
         "$SDK/device/rockchip/rk3576/mlk_afh03_rk3576_defconfig" \
         "$SDK/device/rockchip/.chips/rk3576/mlk_afh03_rk3576_defconfig" \
         "$K/arch/arm64/configs/rockchip_linux_defconfig"; do
    if [ -f "$f" ]; then
        printf '%-95s : ' "${f#$SDK/}"
        if grep -q 'MILIANKE' "$f"; then grep -n 'MILIANKE' "$f" | tr '\n' ' '; echo; else echo "(无 MILIANKE)"; fi
    fi
done

echo
echo "=== .chips/rk3576/mlk_afh03_rk3576_defconfig 是否软链 ==="
ls -la "$SDK/device/rockchip/.chips/rk3576/mlk_afh03_rk3576_defconfig"
echo "--- device/rockchip/.chip (注意单数) 是否存在 ---"
ls -la "$SDK/device/rockchip/.chip" 2>/dev/null | head -20

echo
echo "=== 内核 Makefile 里的 img 目标 ==="
grep -rn 'linux.img' "$K/arch/arm64/Makefile" | head -10

echo
echo "=== 编译产物时间线(改动前记录用) ==="
ls -la --time-style=full-iso "$K/arch/arm64/boot/Image" "$K/arch/arm64/boot/Image.lz4" \
   "$K/resource.img" "$K/boot.img" "$K/vmlinux" "$K/drivers/media/i2c/milianke_mipi.o" 2>/dev/null
