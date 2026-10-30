#!/bin/sh
# Read FPGA JPEG TX status + RK MIPI error counters
B=9
A=0x1a

rd() {
    v=$(i2cget -f -y $B $A "$1" 2>/dev/null)
    printf "  %-4s = %s\n" "$1" "$v"
}

echo "== CFG_VER (expect 0x5402) =="
rd 0xa9
rd 0xaa

echo
echo "== 0x0B JPEG flags (bit0 tx, bit1 dt18, bit2 pad) =="
rd 0x0b

echo
echo "== prev frame byte counts 0xA0..0xA2 =="
rd 0xa0
rd 0xa1
rd 0xa2

echo
echo "== 0xA3 dbg_jpeg (encif_full[3:0], consume, ...) =="
rd 0xa3
rd 0xa4
rd 0xa5
rd 0xa6

echo
echo "== 0xA7 bridge backpressure low8 =="
rd 0xa7

echo
echo "== FIFO level / ready 0xE4 0xE5 0xEF =="
rd 0xe4
rd 0xe5
rd 0xef

echo
echo "== engine diag 0xEA..0xED =="
rd 0xea
rd 0xeb
rd 0xec
rd 0xed

echo
echo "== dmesg: recent CSI/CIF/MIPI lines =="
dmesg | grep -iE "csi|cif|mipi|crc|ecc|size_err|overflow|err" | tail -30

echo
echo "== rkcif debug counters =="
for f in /sys/kernel/debug/rkcif*/**/* 2>/dev/null; do :; done
ls /proc/rkcif* 2>/dev/null
find /sys/kernel/debug -maxdepth 2 -name "*cif*" -o -maxdepth 2 -name "*mipi*" 2>/dev/null | head -10

echo
echo "== v4l2 formats =="
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | head -8
