#!/bin/bash
# 最后一关: rkcif 收 Y8/RAW8 时是否 bypass ISP, 字节流会不会被破坏

K=/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1
CIF=$K/drivers/media/platform/rockchip/cif

echo "=================== 1. cif-luma.c 是什么 ==================="
head -40 "$CIF"/cif-luma.c 2>/dev/null

echo
echo "=================== 2. rkcif 的 GREY 输出路径 ==================="
grep -rn "V4L2_PIX_FMT_GREY" "$CIF"/*.c 2>/dev/null | head -20

echo
echo "=================== 3. rkcif 是否区分 online(走ISP) / offline(直存) ==================="
grep -rn "is_m_online\|RKCIF_MEM_MODE\|mem_mode\|CIF_MEM_MODE" "$CIF"/capture.c 2>/dev/null | head -25

echo
echo "=================== 4. dts 里 rkcif 节点 (是否挂 isp) ==================="
grep -nE "rkcif|rkisp" "$K/arch/arm64/boot/dts/rockchip/rk3576.dtsi" | head -25

echo
echo "=================== 5. AFH03 板级 dts 里 rkcif / rkisp 状态 ==================="
for f in "$K"/arch/arm64/boot/dts/rockchip/AFH03/*.dtsi; do
    hit=$(grep -nE "rkcif|rkisp|mipi3_csi2|mipi_in_fpga" "$f" 2>/dev/null | head -10)
    [ -n "$hit" ] && { echo "--- $(basename $f) ---"; echo "$hit"; }
done

echo
echo "=================== 6. 顶层 dts 引用的 dtsi 清单 ==================="
TOP=$(ls "$K"/arch/arm64/boot/dts/rockchip/*afh03*.dts "$K"/arch/arm64/boot/dts/rockchip/*AFH03*.dts 2>/dev/null | head -1)
echo "TOP=$TOP"
[ -n "$TOP" ] && grep -nE "^#include|^/include/" "$TOP" | head -30

echo
echo "=================== 7. rkcif 驱动里对 RAW8 的写入位宽处理 ==================="
sed -n '960,1000p' "$CIF"/capture.c

echo
echo "=================== 8. rkcif 支持的 V4L2 输出格式表 (含 GREY?) ==================="
grep -rn "cif_fmts\|struct cif_output_fmt" "$CIF"/capture.c | head -10
grep -rn -A3 "V4L2_PIX_FMT_GREY\b" "$CIF"/capture.c | head -30

echo
echo "DONE"
