#!/bin/sh
# ============================================================================
# Bayer 相位 4 选 1 试色 (需要 FPGA 0x450B 及以上)
#
# 0xDA: 0=RGGB  1=GRBG  2=GBRG  3=BGGR
#   实现方式: 两条列相位不同的 demosaic 分支 (RGGB / GBRG) 二选一,
#             再叠加"行相位取反", 因此 4 种顺序都能覆盖, 不用重编。
#
# 用法 (在板子上):
#   sh board_bayer_try.sh
# 然后看 /tmp/bayer_0.jpg .. /tmp/bayer_3.jpg, 哪张颜色正常就把它写回去:
#   i2cset -y 9 0x40 0xda <0|1|2|3>
# ============================================================================
set -u
BUS=9
ADDR=0x40
WEB=http://127.0.0.1:9012/snapshot.jpg

for v in 0 1 2 3; do
    i2cset -y $BUS $ADDR 0xda $v >/dev/null 2>&1
    sleep 1.2
    rb=$(i2cget -y $BUS $ADDR 0xda 2>/dev/null)
    f=/tmp/bayer_$v.jpg
    curl -s -m 6 -o "$f" "$WEB" 2>/dev/null
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    echo "set=$v readback=$rb jpg=$sz"
done

echo "--- 看 /tmp/bayer_0..3.jpg ---"
