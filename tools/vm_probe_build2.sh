#!/bin/bash
SDK="$HOME/mlk-sdk-3576-v1.1.0"
echo "=== build.sh 子命令 (help 尾部) ==="
"$SDK/build.sh" --help 2>&1 | tail -25

echo
echo "=== build.sh kernel 是否合法 ==="
"$SDK/build.sh" kernel --help 2>&1 | head -15

echo
echo "=== boot.img 指纹 ==="
md5sum "$SDK/kernel-6.1/boot.img" "$SDK/output/firmware/boot.img" 2>/dev/null
ls -la "$SDK/kernel-6.1/boot.img"

echo
echo "=== 上次 build.log 里的关键行 (defconfig 选择 / 打包) ==="
L="$SDK/output/sessions/2026-10-09_22-54-17"
grep -n -E 'defconfig|CHIP|rk3576\.config|Image\.lz4|boot\.img|resource\.img|mkimage' "$L/build.log" 2>/dev/null | head -25

echo
echo "=== 内核树里被官方改过的 RK 相关文件 (drivers/media/i2c 附近) ==="
ls -la "$SDK/kernel-6.1/drivers/media/i2c/" | grep -i -E 'milianke|afh|afc' 
