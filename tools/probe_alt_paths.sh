#!/bin/bash
# 探查 MIPI 之外的候选通路: FlexBus (含 JPEG_1X8) / PCIe / ETH
# 目标: 找到一条能承载 JPEG 字节流进入 RK 的物理通道

SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
K=$SDK/kernel-6.1
FB=$K/drivers/media/platform/rockchip/flexbus_cif

echo "=================== 1. flexbus_cif 是否存在 ==================="
ls -la "$FB" 2>/dev/null | head -20

echo
echo "=================== 2. flexbus_cif 的 mbus code 表 ==================="
grep -rhn "MEDIA_BUS_FMT_[A-Z0-9_]*" "$FB"/*.c "$FB"/*.h 2>/dev/null \
    | grep -oE "MEDIA_BUS_FMT_[A-Z0-9_]+" | sort -u

echo
echo "=================== 3. flexbus_cif 的输出 fourcc ==================="
grep -rhn "V4L2_PIX_FMT_[A-Z0-9_]*" "$FB"/*.c "$FB"/*.h 2>/dev/null \
    | grep -oE "V4L2_PIX_FMT_[A-Z0-9_]+" | sort -u

echo
echo "=================== 4. flexbus_cif 是否真的有 JPEG 分支 (不只是名字表) ==================="
grep -rn "JPEG_1X8" "$FB"/*.c "$FB"/*.h 2>/dev/null

echo
echo "=================== 5. flexbus_cif 里的 0x18 / DT 处理 ==================="
grep -rn "0x18" "$FB"/*.c 2>/dev/null | head -20

echo
echo "=================== 6. CONFIG: flexbus / pcie ==================="
grep -E "CONFIG_VIDEO_ROCKCHIP_FLEXBUS|CONFIG_ROCKCHIP_FLEXBUS|CONFIG_PCIE_ROCKCHIP|CONFIG_PCIE_DW_ROCKCHIP" "$K/.config" 2>/dev/null

echo
echo "=================== 7. dts 里 flexbus 节点 ==================="
grep -rn "flexbus" "$K/arch/arm64/boot/dts/rockchip/rk3576.dtsi" 2>/dev/null | head -20

echo
echo "=================== 8. AFH03 板级 dts 里 flexbus / pcie 状态 ==================="
for f in "$K"/arch/arm64/boot/dts/rockchip/AFH03/*.dtsi "$K"/arch/arm64/boot/dts/rockchip/AFH03/*.dts; do
    [ -f "$f" ] || continue
    hit=$(grep -nE "flexbus|pcie" "$f" 2>/dev/null | head -8)
    if [ -n "$hit" ]; then
        echo "--- $(basename $f) ---"
        echo "$hit"
    fi
done

echo
echo "=================== 9. rk3576.dtsi 里 pcie 节点 ==================="
grep -nE "pcie[0-9]*:|pcie[0-9]*_" "$K/arch/arm64/boot/dts/rockchip/rk3576.dtsi" 2>/dev/null | head -15

echo
echo "=================== 10. rk3576.dtsi 里 flexbus 完整定义 ==================="
awk '/flexbus/,/};/' "$K/arch/arm64/boot/dts/rockchip/rk3576.dtsi" 2>/dev/null | head -40

echo
echo "=================== 11. 是否有其他 JPEG 直通驱动 (rkvdec/rkvenc 不算) ==================="
grep -rln "MEDIA_BUS_FMT_JPEG_1X8" "$K/drivers/media/" 2>/dev/null

echo
echo "=================== 12. 板级 dts 顶层文件 ==================="
ls -la "$K"/arch/arm64/boot/dts/rockchip/AFH03/ 2>/dev/null

echo
echo "DONE"
