#!/bin/sh
# 定量: JPEG 编码产出率 vs 采集帧率 vs MIPI 错误率
rd() { i2cget -y 9 0x40 "$1" 2>/dev/null; }

f32() {
  b0=$(rd 0xB8); b1=$(rd 0xB9); b2=$(rd 0xBA); b3=$(rd 0xBB)
  echo $(( (b3<<24) | (b2<<16) | (b1<<8) | b0 ))
}

J0=$(f32)
C0=$(( $(rd 0xD0) ))
A0=$(rd 0xA0); A1=$(rd 0xA1); A2=$(rd 0xA2)
BY0=$(( (A2<<16) | (A1<<8) | A0 ))
echo "T0: JPEG完成帧=$J0  采集帧=$C0  累计字节=$BY0"

dmesg -c >/dev/null 2>&1
sleep 5

J1=$(f32)
C1=$(( $(rd 0xD0) ))
A0=$(rd 0xA0); A1=$(rd 0xA1); A2=$(rd 0xA2)
BY1=$(( (A2<<16) | (A1<<8) | A0 ))
M=$(dmesg | grep -c MIPI_CSI2)

echo "T1: JPEG完成帧=$J1  采集帧=$C1  累计字节=$BY1"
echo
echo "======== 5 秒内 ========"
DJ=$((J1-J0)); [ $DJ -lt 0 ] && DJ=$((DJ+4294967296))
DC=$((C1-C0)); [ $DC -lt 0 ] && DC=$((DC+256))
DBY=$((BY1-BY0)); [ $DBY -lt 0 ] && DBY=$((DBY+16777216))

echo "  JPEG 完成帧 : +$DJ  => $((DJ/5)) fps"
echo "  采集帧      : +$DC  => $((DC/5)) fps"
echo "  累计字节    : +$DBY => $((DBY/5/1024)) KB/s"
echo "  MIPI 错误   : $M  => $((M/5)) 条/秒"
echo
if [ "$DJ" -gt 0 ]; then
  echo "  >>> 编码器在持续产出完整帧"
  echo "      每 5 秒 $DJ 帧完整 JPEG -> 若 RK 仍无图, 问题在传输/接收侧"
  if [ "$DBY" -gt 0 ] && [ "$DJ" -gt 0 ]; then
    echo "      平均每帧字节 = $((DBY/DJ)) B  (3840x1080 的 NV16 是 8294400 B)"
  fi
else
  echo "  >>> 编码器没有完成任何帧"
fi
