#!/bin/sh
# 判别: MIPI 错误是与"字节数"成正比, 还是与"包数"成正比?
rd() { i2cget -y 9 0x40 "$1" 2>/dev/null; }
f32() { b0=$(rd 0xB8); b1=$(rd 0xB9); b2=$(rd 0xBA); b3=$(rd 0xBB); echo $(( (b3<<24)|(b2<<16)|(b1<<8)|b0 )); }
byt() { b0=$(rd 0xA0); b1=$(rd 0xA1); b2=$(rd 0xA2); echo $(( (b2<<16)|(b1<<8)|b0 )); }

probe() {
  J0=$(f32); B0=$(byt)
  dmesg -c >/dev/null 2>&1
  sleep 4
  J1=$(f32); B1=$(byt); M=$(dmesg | grep -c MIPI_CSI2)
  DJ=$((J1-J0)); [ $DJ -lt 0 ] && DJ=$((DJ+4294967296))
  DB=$((B1-B0)); [ $DB -lt 0 ] && DB=$((DB+16777216))
  echo "  帧=$DJ 字节=$DB 错误=$M"
  echo "$DJ $DB $M"
}

qt() { i=0; while [ $i -lt 128 ]; do i2cset -y 9 0x40 $((0x10+i)) $1 2>/dev/null; i=$((i+1)); done; }

echo "=== A. 当前 qtable (基线) ==="
A=$(probe | tail -1)

echo
echo "=== B. qtable 全 255 (最强压缩, 码率大幅下降) ==="
qt 0xFF; sleep 3
B=$(probe | tail -1)

echo
echo "=== C. 恢复 qtable = 8 ==="
qt 0x08; sleep 3
C=$(probe | tail -1)

echo
echo "======== 结果 ========"
set -- $A; AJ=$1; AB=$2; AM=$3
set -- $B; BJ=$1; BB=$2; BM=$3
set -- $C; CJ=$1; CB=$2; CM=$3

echo "  A 基线    : 帧=$AJ  字节=$AB  错误=$AM"
echo "  B 强压缩  : 帧=$BJ  字节=$BB  错误=$BM"
echo "  C 恢复    : 帧=$CJ  字节=$CB  错误=$CM"
echo
if [ "$AB" -gt 0 ] && [ "$BB" -gt 0 ] && [ "$AM" -gt 0 ] && [ "$BM" -gt 0 ]; then
  echo "  字节比 B/A   = $(( BB * 100 / AB ))%"
  echo "  错误比 B/A   = $(( BM * 100 / AM ))%"
  echo "  每帧包数(1024B/包): A=$(( AB / AJ / 1024 + 1 ))  B=$(( BB / BJ / 1024 + 1 ))"
  echo
  EBR=$(( BM * 100 / AM )); ZBR=$(( BB * 100 / AB ))
  echo "  若 错误比 ≈ 字节比  -> 误码与字节数成正比 (物理层随机误码, 降码率有效)"
  echo "  若 错误比 >> 字节比  -> 误码与包数/包边界相关 (改 PKT_BYTES / GAP 有效)"
  echo "    (字节比=${ZBR}%  错误比=${EBR}%)"
fi
