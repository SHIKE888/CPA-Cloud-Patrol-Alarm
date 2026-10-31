#!/bin/sh
# V54r (0x540E) 验证: 变长包 WC 4 字节对齐后 MIPI 错误率
rd() { i2cget -y 9 0x40 "$1" 2>/dev/null; }

V9=$(rd 0xA9); VA=$(rd 0xAA)
echo "版本 = 0x$(printf '%02X%02X' $((VA)) $((V9)))    (期望 0x540E)"
echo

echo "=== MIPI 错误率 (5 秒窗口) ==="
dmesg -c >/dev/null 2>&1
sleep 5
N=$(dmesg | grep -c MIPI_CSI2)
echo "  新增 $N 条  =>  $((N/5)) 条/秒"
echo "  历史: V54q=854/s  V54p=874/s"
echo
if [ "$N" -lt 50 ]; then
  echo "  >>>>>> 错误基本消失! 对齐修复生效 <<<<<<"
elif [ "$N" -lt 300 ]; then
  echo "  >>>>>> 错误大幅下降 <<<<<<"
else
  echo "  >>>>>> 错误仍然很多 <<<<<<"
fi
echo

echo "=== 错误分类 ==="
echo -n "  ecc: "; dmesg | grep -c '(ecc'
echo -n "  crc: "; dmesg | grep -c '(crc'
echo -n "  err id: "; dmesg | grep -c 'err id'
echo

echo "=== VC 分布 (正常应全部 vc: 0) ==="
dmesg | grep MIPI_CSI2 | grep -oE 'vc: [0-9 ]+' | sort | uniq -c | sort -rn | head -6
echo

echo "=== 引擎产出 (应约 41fps) ==="
B0=$(rd 0xB8); B1=$(rd 0xB9); B2=$(rd 0xBA); B3=$(rd 0xBB)
J1=$(( (B3<<24) | (B2<<16) | (B1<<8) | B0 ))
A0=$(rd 0xA0); A1=$(rd 0xA1); A2=$(rd 0xA2)
Y1=$(( (A2<<16) | (A1<<8) | A0 ))
sleep 5
B0=$(rd 0xB8); B1=$(rd 0xB9); B2=$(rd 0xBA); B3=$(rd 0xBB)
J2=$(( (B3<<24) | (B2<<16) | (B1<<8) | B0 ))
A0=$(rd 0xA0); A1=$(rd 0xA1); A2=$(rd 0xA2)
Y2=$(( (A2<<16) | (A1<<8) | A0 ))
F5=$((J2-J1)); Y5=$((Y2-Y1))
echo "  JPEG帧: $J1 -> $J2   (+$F5 / 5s = $((F5/5)) fps)"
echo "  字节:   $Y1 -> $Y2   (+$Y5 / 5s = $((Y5/5/1024)) KB/s)"
if [ "$F5" -gt 0 ]; then echo "  每帧字节 = $((Y5/F5))"; fi
echo

echo "=== 采集 ==="
echo "  corr_frames(0xD0)=$(rd 0xD0)  st_frames(0xE1)=$(rd 0xE1)"
echo "  l_ovf(0xDC)=$(rd 0xDC)  r_ovf(0xD5)=$(rd 0xD5)"
echo "  桥 rcnt(0xE4)=$(rd 0xE4)  lvl(0xE5)=$(rd 0xE5)  bp(0xA7)=$(rd 0xA7)"
echo

echo "=== RK 侧缓冲首字节 (应为 FF D8 = JPEG SOI) ==="
dmesg -c >/dev/null 2>&1
python3 - <<'PYEOF'
import fcntl, mmap, struct
try:
    f = open('/dev/video22','rb',buffering=0)
    buf = mmap.mmap(-1, 4147200)
    for i in range(4):
        b = struct.pack('I', i)
        try: fcntl.ioctl(f.fileno(), 0xc050561a, b+bytes(80))
        except Exception as e: pass
    fcntl.ioctl(f.fileno(), 0xc0145612, buf)
    d = buf[:32]
    print('  前32字节: ' + ' '.join('%02X'%x for x in d))
    if d[0]==0xFF and d[1]==0xD8:
        print('  >>>>>> 是 JPEG SOI! 驱动已识别码流 <<<<<<')
    else:
        print('  未识别为 JPEG (NV16 解析)')
except Exception as e:
    print('  读缓冲失败: %s' % e)
PYEOF
