#!/bin/sh
# 画面冻结定位 (CFG_VER 0x4702 起有 0xE1~0xE9 全套诊断)
DEV=9
A=0x40
g() { printf '%s' "$(i2cget -y $DEV $A $1 2>/dev/null)"; }
n() { printf '%d' "$(g $1)" 2>/dev/null || echo 0; }

dump() {
    echo "  E1 sof_cnt   = $(g 0xe1)"
    echo "  E2 wbuf_idx  = $(g 0xe2)"
    echo "  E3 vtc_vs    = $(g 0xe3)"
    echo "  E4/E5 cam1行宽= $(( $(n 0xe4) + 256 * $(n 0xe5) ))"
    echo "  E6 tlast_cnt = $(g 0xe6)"
    echo "  E7 rxclk_cnt = $(g 0xe7)   <- 不变 => S_hs_rx_clk 停摆"
    echo "  E8 clk1_cnt  = $(g 0xe8)   <- 不变 => cam1 恢复时钟停摆"
    echo "  E9 rx1tvalid = $(g 0xe9)   <- 不变 => RX 没有输出数据"
}

echo "版本: A9=$(g 0xa9) AA=$(g 0xaa)   DB=$(g 0xdb)"
echo "--- t0 ---"
dump
sleep 2
echo "--- t1 (2s 后) ---"
dump
echo ""
echo "0xD4/D5 cam0 行宽 = $(( $(n 0xd4) + 256 * $(n 0xd5) ))"
echo "0xDC=$(g 0xdc)  0xD6=$(g 0xd6)  0xDD=$(g 0xdd)  0xDE=$(g 0xde)  0xDF=$(g 0xdf)"
