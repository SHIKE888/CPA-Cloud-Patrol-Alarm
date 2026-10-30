#!/bin/bash
# 验证「把 MIPI 当 8bit 字节管道」的可行性:
#   FPGA 用 DT=0x2A(RAW8) 发 JPEG 字节流 -> rkcif 当 RAW8/GREY 收
#   -> 用户态读出原始字节 -> 拼回 JPEG 解码
# 需要确认: rkcif 的 DT<->mbus 映射、尺寸上限、bypass ISP 支持

K=/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1
CIF=$K/drivers/media/platform/rockchip/cif

echo "=================== 1. rkcif 的 MIPI DT -> mbus 映射表 ==================="
grep -rn "0x2a\|0x2A\|RAW8\|Y8_1X8" "$CIF"/capture.c 2>/dev/null | head -30

echo
echo "=================== 2. rkcif 里 MEDIA_BUS_FMT_Y8_1X8 / S*GGB8 处理 ==================="
grep -rn "MEDIA_BUS_FMT_Y8_1X8\|MEDIA_BUS_FMT_SRGGB8_1X8\|MEDIA_BUS_FMT_UV8_1X8" "$CIF"/*.c 2>/dev/null | head -20

echo
echo "=================== 3. rkcif 最大 width / height ==================="
grep -rn "RKCIF_MAX_WIDTH\|RKCIF_MAX_HEIGHT\|max_width\|max_height" "$CIF"/*.h "$CIF"/*.c 2>/dev/null | head -20

echo
echo "=================== 4. rkcif 是否支持 bypass ISP (direct/online 区分) ==================="
grep -rn "RKCIF_MEM_MODE\|mem_mode\|online\|iommu_en\|direct" "$CIF"/dev.h 2>/dev/null | head -20

echo
echo "=================== 5. rkcif 的 DT 取值宏 ==================="
grep -rn "CSI2_DT\|MIPI_CSI2_DT" "$CIF"/*.h "$CIF"/*.c 2>/dev/null | head -30

echo
echo "=================== 6. rkcif 解析 CSI-2 数据类型的函数 ==================="
grep -rn "data_type\|csi_fmt\|csiphy" "$CIF"/capture.c 2>/dev/null | grep -i "case\|switch\|==" | head -25

echo
echo "=================== 7. 现有 milianke 驱动 set_fmt 尺寸裁剪逻辑 ==================="
sed -n '160,240p' "$K/drivers/media/i2c/milianke_mipi.c"

echo
echo "=================== 8. 板级 csi-imx415 里 fpga 节点的 data-lanes / link-freq ==================="
sed -n '30,60p' "$K/arch/arm64/boot/dts/rockchip/AFH03/csi-imx415-2.dtsi"

echo
echo "=================== 9. rk3576 的 csi2 dphy 最大速率 ==================="
grep -rn "max.*lane\|1500\|2500\|link_freq" "$K/drivers/phy/rockchip/phy-rockchip-csi2-dphy*.c" 2>/dev/null | head -15

echo
echo "DONE"
