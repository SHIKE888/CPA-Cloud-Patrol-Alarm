#!/bin/sh
# 高频采样 0xDC (两路打包状态) 看 in_frame 位会不会翻转。
# 若 cam1 的 in_frame 一直为 1 不回落 -> RX 没有帧边界 -> tuser 只来一次
# -> dbuf 写状态机不再轮转 -> 画面冻结。
N=${1:-300}
DEV=9
A=0x40
i=0
ones=0
zeros=0
prev=""
changes=0
while [ $i -lt $N ]; do
    v=$(i2cget -y $DEV $A 0xdc 2>/dev/null)
    b1=$(( (v & 0x02) >> 1 ))      # cam1 in_frame
    b0=$(( v & 0x01 ))             # cam0 in_frame
    if [ "$b1" = "1" ]; then ones=$((ones+1)); else zeros=$((zeros+1)); fi
    if [ -n "$prev" ] && [ "$b1" != "$prev" ]; then changes=$((changes+1)); fi
    prev=$b1
    i=$((i+1))
done
echo "采样 $N 次 0xDC:"
echo "  cam1 in_frame=1 : $ones 次"
echo "  cam1 in_frame=0 : $zeros 次   <- 这个为 0 说明没有帧边界(冻结)"
echo "  电平翻转        : $changes 次 <- 至少应该看到几次"
