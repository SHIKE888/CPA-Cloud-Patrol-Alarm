#!/bin/sh
# ============================================================================
# CSI RX 手动 tap 扫描 (配合 FPGA 0x450A+)
#
# 原理: FPGA 侧 jpeg_regfile 的 0xD9 写一次 = 给 RX 的 I_debug_button 一次
#       "按下->释放" 脉冲; csi_rx_phy 里:
#         第一次释放沿 = 锁存当前自动 tap 并进入手动模式
#         之后每次释放沿 = tap + 1 (6bit, 只有 0..31 有效)
#
# 用法 (在板子上):
#   sh board_csi_tap_sweep.sh
# 产出: /tmp/tapsweep/stepNN_d7=0xXX.jpg + 终端打印 d7/d8
# 之后把这些 jpg 拉回本地算指标, 挑出画面正常的那一档 tap。
# ============================================================================
set -u
OUT=/tmp/tapsweep
WEB=http://127.0.0.1:9012/snapshot.jpg
BUS=9
ADDR=0x40

rm -rf "$OUT"
mkdir -p "$OUT"

i=0
while [ $i -le 32 ]; do
    # 1) 步进一次
    i2cset -y $BUS $ADDR 0xd9 1 >/dev/null 2>&1
    sleep 0.5

    d7=$(i2cget -y $BUS $ADDR 0xd7 2>/dev/null)
    d8=$(i2cget -y $BUS $ADDR 0xd8 2>/dev/null)
    d6=$(i2cget -y $BUS $ADDR 0xd6 2>/dev/null)

    f=$(printf "%s/step%02d_d7%s.jpg" "$OUT" "$i" "$d7")
    curl -s -m 6 -o "$f" "$WEB" 2>/dev/null
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)

    echo "step=$i d6=$d6 d7=$d7 d8=$d8 jpg=$sz"
    i=$((i + 1))
done

echo "--- done: $OUT ---"
