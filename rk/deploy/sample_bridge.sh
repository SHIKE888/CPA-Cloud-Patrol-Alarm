#!/bin/sh
# Sample JPEG byte-bridge counters repeatedly to see if data is flowing at all.
# 0xE4 = bridge level low8, 0xE5 = bytes read out count, 0xEF = diag
B=9
A=0x40

echo " time  E4(lvl) E5(rcnt) EF   A0-A2(framebytes)  A3(ovf/stall)"
i=0
while [ $i -lt 12 ]; do
    e4=$(i2cget -y $B $A 0xe4 2>/dev/null)
    e5=$(i2cget -y $B $A 0xe5 2>/dev/null)
    ef=$(i2cget -y $B $A 0xef 2>/dev/null)
    a0=$(i2cget -y $B $A 0xa0 2>/dev/null)
    a1=$(i2cget -y $B $A 0xa1 2>/dev/null)
    a2=$(i2cget -y $B $A 0xa2 2>/dev/null)
    a3=$(i2cget -y $B $A 0xa3 2>/dev/null)
    printf "%5d  %-7s %-7s %-5s %s%s%s              %s\n" \
        "$i" "$e4" "$e5" "$ef" "$a2" "$a1" "$a0" "$a3"
    i=$((i + 1))
    sleep 0.5
done

echo
echo "== bit decode of 0xEF =="
echo "  [1:0] jl_st (0=DATA 1=PAD 2=DROP)"
echo "  [2] dsi_pll_lock  [3] jpeg_pad"
echo "  [4] jb_r (bridge read enable)  [5] jv_rx_ready (TX ready)"
echo "  [6] jb_v (bridge valid)        [7] jb_l (bridge last)"
