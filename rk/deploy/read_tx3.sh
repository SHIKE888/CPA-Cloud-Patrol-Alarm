#!/bin/sh
# Read FPGA regs with stream STOPPED (rkcif holds i2c while streaming)
B=9
A=0x1a

rd() {
    v=$(i2cget -y $B $A "$1" 2>/dev/null)
    printf "  %-4s = %s\n" "$1" "${v:-<fail>}"
}

systemctl stop mipi-webstream
sleep 2

echo "== CFG_VER =="
rd 0xa9
rd 0xaa

echo
echo "== 0x0B flags [0]=tx [1]=dt18 [2]=pad =="
rd 0x0b

echo
echo "== prev frame byte count 0xA0-A2 =="
rd 0xa0
rd 0xa1
rd 0xa2

echo
echo "== 0xA3-A6 dbg_jpeg =="
rd 0xa3
rd 0xa4
rd 0xa5
rd 0xa6

echo
echo "== 0xA7 bridge bp / 0xE4-E5 bridge level+cnt =="
rd 0xa7
rd 0xe4
rd 0xe5

echo
echo "== 0xEF diag (bit0-1 jl_st, 2 dsi_pll_lock, 3 pad, 4 jb_r, 5 jv_ready, 6 jb_v, 7 jb_l) =="
rd 0xef

echo
echo "== engine diag 0xEA-ED =="
rd 0xea
rd 0xeb
rd 0xec
rd 0xed

echo
echo "== frame cycles 0xA8 =="
rd 0xa8

systemctl start mipi-webstream
sleep 1
echo
echo "== web restarted: $(systemctl is-active mipi-webstream) =="
