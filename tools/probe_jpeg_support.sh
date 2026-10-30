#!/bin/bash
# 探查 rkcif 是否支持 JPEG over CSI-2 (DT=0x18)。
# 这是"硬指标走 JPEG"路线能否成立的唯一前提。
# 用法: powershell -ExecutionPolicy Bypass -File tools\vmsh.ps1 -File tools\probe_jpeg_support.sh

SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
K=$SDK/kernel-6.1
CIF=$K/drivers/media/platform/rockchip/cif

echo "=================== 1. 内核版本 ==================="
if [ -f "$K/Makefile" ]; then
    grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL)' "$K/Makefile" | head -3
else
    echo "!! 内核树不存在: $K"
    exit 1
fi

echo
echo "=================== 2. rkcif 是否认 JPEG 输出格式 ==================="
echo "--- RK_CIF_FMT_JPEG / V4L2_PIX_FMT_JPEG ---"
grep -rn "RK_CIF_FMT_JPEG\|V4L2_PIX_FMT_JPEG" "$CIF" 2>/dev/null | head -20
echo "(空 = rkcif 不直接支持 JPEG 输出)"

echo
echo "=================== 3. rkcif 对 DT=0x18 的处理 ==================="
grep -rn "0x18\|DT_JPEG\|MIPI_CSI2_DT_JPEG\|data_type" "$CIF"/*.c 2>/dev/null | grep -i "jpeg\|0x18" | head -20
echo "(空 = 不认识 JPEG 数据类型)"

echo
echo "=================== 4. rkcif 接受的 mbus code 清单 ==================="
grep -rhn "MEDIA_BUS_FMT_[A-Z0-9_]*" "$CIF"/capture.c 2>/dev/null \
    | grep -oE "MEDIA_BUS_FMT_[A-Z0-9_]+" | sort -u | head -40

echo
echo "=================== 5. 全 rockchip 目录里的 JPEG_1X8 ==================="
grep -rn "MEDIA_BUS_FMT_JPEG_1X8" "$K/drivers/media/platform/rockchip/" 2>/dev/null | head -20
echo "(空 = 没有现成先例, 需要自己加)"

echo
echo "=================== 6. rkcif 支持的输出 fourcc ==================="
grep -rn "V4L2_PIX_FMT_" "$CIF"/capture.c 2>/dev/null \
    | grep -oE "V4L2_PIX_FMT_[A-Z0-9_]+" | sort -u | head -40

echo
echo "=================== 7. 当前驱动 ==================="
ls -la "$K/drivers/media/i2c/milianke_mipi.c" 2>/dev/null
md5sum "$K/drivers/media/i2c/milianke_mipi.c" 2>/dev/null

echo
echo "=================== 8. 历史备份 ==================="
ls -1dt /home/uisrc/kernel-backup/*/ 2>/dev/null | head -5

echo
echo "=================== 9. boot.img 现状 ==================="
ls -la "$K/boot.img" 2>/dev/null
md5sum "$K/boot.img" 2>/dev/null

echo
echo "=================== 10. dts 里 fpga sensor 节点 ==================="
grep -rn "milianke,fpga-virtual" "$K/arch/arm64/boot/dts/rockchip/" 2>/dev/null | head -10

echo
echo "=================== 11. rkcif 是否编译进内核 ==================="
grep -E "CONFIG_VIDEO_ROCKCHIP_CIF|CONFIG_VIDEO_MILIANKE" "$K/.config" 2>/dev/null

echo
echo "DONE"
