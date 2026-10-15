#!/bin/bash
# 验证 RES_MODE 死锁修复: 切到 4K30 再切回 1080p60, 看画面能否自己恢复
B=http://127.0.0.1:9012
api() { curl -s -m 20 "$@"; }
st() {
  curl -s -m 10 $B/api/status \
    | grep -o '"fps": [0-9.]*\|"width": [0-9]*\|"height": [0-9]*' | head -3 | tr '\n' ' '
  echo
}
rg() { python3 /root/rk/deploy/fpga_cfg.py get "$1" 2>&1 | tail -1; }
rs() { python3 /root/rk/deploy/fpga_cfg.py set "$1" "$2" 2>&1 | tail -1; }

echo "=== A. 基线 (1080p60) ==="
printf "  RES_MODE(0xE0) = "; rg 0xE0
printf "  FPS_DIV (0xC7) = "; rg 0xC7
printf "  status: "; st
curl -s -m 12 --output /root/a_1080p60.jpg $B/snapshot.jpg
ls -l /root/a_1080p60.jpg

echo
echo "=== B. 切到 4K30 (RES_MODE=1) —— 改动前这一步就会把发送通路卡死 ==="
rs 0xE0 1
sleep 7
printf "  RES_MODE = "; rg 0xE0
printf "  status   : "; st

echo
echo "=== C. 切回 1080p60 (RES_MODE=0) —— 关键: 能否自己恢复 ==="
rs 0xE0 0
sleep 10
printf "  RES_MODE = "; rg 0xE0
printf "  status   : "; st
curl -s -m 12 --output /root/c_back.jpg $B/snapshot.jpg
ls -l /root/c_back.jpg

echo
echo "=== D. 采集日志尾部 ==="
tail -10 /tmp/webstream.log
