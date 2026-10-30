#!/bin/sh
# Read FPGA regs (plain i2cget) + count MIPI errors
B=9
A=0x1a

rd() {
    v=$(i2cget -y $B $A "$1" 2>/dev/null)
    printf "  %-4s = %s\n" "$1" "${v:-<fail>}"
}

echo "== CFG_VER =="
rd 0xa9
rd 0xaa

echo
echo "== 0x0B flags / 0xA0-A2 bytes / 0xA7 bp =="
rd 0x0b
rd 0xa0
rd 0xa1
rd 0xa2
rd 0xa7

echo
echo "== 0xA3-A6 dbg_jpeg =="
rd 0xa3
rd 0xa4
rd 0xa5
rd 0xa6

echo
echo "== 0xE4 E5 EF FIFO/ready =="
rd 0xe4
rd 0xe5
rd 0xef

echo
echo "== 0xEA-ED engine diag =="
rd 0xea
rd 0xeb
rd 0xec
rd 0xed

echo
echo "== MIPI error counts by type (last 5000 dmesg lines) =="
dmesg | tail -5000 | grep -oE "\((ecc2|ecc|crc|err id)[^)]*\)" | sort | uniq -c | sort -rn | head -15

echo
echo "== total MIPI error lines =="
dmesg | grep -c "MIPI_CSI2"

echo
echo "== v4l2 current fmt =="
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | head -6
