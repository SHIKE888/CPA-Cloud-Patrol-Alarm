#!/bin/bash
# 增量编译内核 (只改了驱动 -> 重编 .o + 重链 vmlinux + 打 boot.img)
SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
K=$SDK/kernel-6.1
CC=$SDK/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-
TS=$(date +%Y%m%d-%H%M%S)
LOG=$HOME/kernel-build-agent-$TS.log

echo "=== 编译前 ==="
date -Is
ls -la --time-style=full-iso "$K/drivers/media/i2c/milianke_mipi.o" 2>/dev/null
ls -la --time-style=full-iso "$K/arch/arm64/boot/Image" "$K/boot.img" 2>/dev/null
echo "  驱动 md5: $(md5sum "$K/drivers/media/i2c/milianke_mipi.c" | cut -d' ' -f1)"
echo "  .config 里的驱动开关: $(grep 'CONFIG_VIDEO_MILIANKE_FPGA_VIRTUAL' "$K/.config")"

echo
echo "=== 开始增量编译 (日志: $LOG) ==="
date -Is
make -C "$SDK/kernel/" -j17 CROSS_COMPILE="$CC" ARCH=arm64 mlk-afh03-rk3576-linux.img > "$LOG" 2>&1
rc=$?
date -Is

echo
echo "=== make 退出码: $rc ==="
if [ $rc -ne 0 ]; then
    echo "--- 错误摘要 ---"
    grep -nE 'error:|Error [0-9]+|No rule|fatal' "$LOG" | head -40
    echo "--- 日志尾部 ---"
    tail -40 "$LOG"
    exit $rc
fi

echo
echo "=== 编译后产物 ==="
ls -la --time-style=full-iso "$K/drivers/media/i2c/milianke_mipi.o" \
    "$K/arch/arm64/boot/Image" "$K/arch/arm64/boot/Image.lz4" \
    "$K/resource.img" "$K/boot.img" "$K/zboot.img" 2>/dev/null
echo
echo "  新 boot.img md5 : $(md5sum "$K/boot.img" | cut -d' ' -f1)"
echo "  基线 md5        : 0deb3ac78d3ce5861b847f31d88e9414"
echo "  (必须不同, 否则说明没编进去)"
echo
echo "=== 编译告警/错误 ==="
grep -nE 'error:|warning:' "$LOG" | grep -i milianke || echo "  驱动无警告/错误"
grep -cE 'error:' "$LOG" | xargs echo "  全文 error: 数量 ="
echo
echo "=== 日志尾部 20 行 ==="
tail -20 "$LOG"
