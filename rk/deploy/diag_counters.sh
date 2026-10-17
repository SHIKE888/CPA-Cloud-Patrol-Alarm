#!/bin/sh
# 只读探测: 判断写表链路/JPEG/各计数器是否活着
F=/root/rk/deploy/fpga_cfg.py
g() { python3 $F get $1 2>&1 | tail -1 | sed 's/.*= //'; }

echo "=== 计数器第一次 ==="
for r in 0xB8 0xB9 0xBA 0xBB 0xD0 0xD1 0xD2 0xD3 0xBC 0xA0 0xA1 0xA2 0xA3 0xA4 0xA5 0xA6 0xA8; do
  printf "  %s = %s\n" "$r" "$(g $r)"
done
echo ""
echo "=== 等 10 秒 ==="
sleep 10
echo "=== 计数器第二次 (看谁在变) ==="
for r in 0xB8 0xB9 0xBA 0xBB 0xD0 0xD1 0xD2 0xBC 0xA3 0xA4 0xA5 0xA6 0xA8; do
  printf "  %s = %s\n" "$r" "$(g $r)"
done
echo ""
echo "=== 线性读数 (十进制) 便于比较 ==="
b8=$(g 0xB8 | sed 's/.*(//;s/).*//'); b9=$(g 0xB9 | sed 's/.*(//;s/).*//')
bA=$(g 0xBA | sed 's/.*(//;s/).*//'); bB=$(g 0xBB | sed 's/.*(//;s/).*//')
echo "  FRAME_CNT = $((bB*16777216 + bA*65536 + b9*256 + b8))"
