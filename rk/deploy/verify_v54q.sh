#!/bin/sh
# V54q 验证: FS/FE 短包修复后 MIPI 错误率
rd() { i2cget -y 9 0x40 "$1" 2>/dev/null; }

V9=$(rd 0xA9); VA=$(rd 0xAA)
echo "版本 = 0x$(printf '%02X%02X' $((VA)) $((V9)))    (期望 0x540D)"
echo

echo "=== MIPI 错误率 (5 秒窗口) ==="
dmesg -c >/dev/null 2>&1
sleep 5
N=$(dmesg | grep -c MIPI_CSI2)
echo "  新增 $N 条  =>  $((N/5)) 条/秒    (修复前约 874 条/秒)"
echo
if [ "$N" -lt 50 ]; then
  echo "  >>>>>> 错误几乎消失! 短包修复生效 <<<<<<"
elif [ "$N" -lt 500 ]; then
  echo "  >>>>>> 错误显著下降, 继续观察 <<<<<<"
else
  echo "  >>>>>> 错误仍然很多 <<<<<<"
fi
echo

echo "=== 错误类型分布 ==="
dmesg | grep MIPI_CSI2 | grep -oE 'ecc2|err id|\(crc|\(ecc' | sort | uniq -c | sort -rn | head -6
echo

echo "=== VC 分布 (FPGA 只发 VC0) ==="
dmesg | grep MIPI_CSI2 | grep -oE 'vc: [0-9 ]+' | sort | uniq -c | sort -rn | head -6
echo

echo "=== 引擎产出 ==="
B0=$(rd 0xB8); B1=$(rd 0xB9); B2=$(rd 0xBA); B3=$(rd 0xBB)
J=$(( (B3<<24) | (B2<<16) | (B1<<8) | B0 ))
A0=$(rd 0xA0); A1=$(rd 0xA1); A2=$(rd 0xA2)
BY=$(( (A2<<16) | (A1<<8) | A0 ))
echo "  JPEG完成帧 = $J   累计字节 = $BY"
echo

echo "=== 采集 / 拼接 ==="
echo "  corr_frames(0xD0) = $(rd 0xD0)   st_frames(0xE1) = $(rd 0xE1)"
echo "  l_ovf(0xDC)=$(rd 0xDC)  r_ovf(0xD5)=$(rd 0xD5)"
echo

echo "=== 桥 ==="
echo "  rcnt(0xE4)=$(rd 0xE4)  lvl(0xE5)=$(rd 0xE5)  bp(0xA7)=$(rd 0xA7)"
