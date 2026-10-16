#!/bin/sh
echo "=== A) FPGA 原始寄存器 0xC0-0xE8 (含 0xD4/0xD5 行组数) ==="
python3 /root/rk/deploy/fpga_cfg.py scan 2>/dev/null | head -5
echo "--- 逐个读 ---"
for a in C0 C1 C2 C3 C4 C5 C6 C7 C8 C9 CA CB CC CD CE CF D0 D1 D2 D3 D4 D5 D6 D7 D8 D9 DA DB DC DD DE DF E0 E1 E2 E3; do
  v=$(python3 /root/rk/deploy/fpga_cfg.py get 0x$a 2>/dev/null)
  echo "  0x$a = $v"
done

echo ""
echo "=== B) 清空 dmesg, 干净抓 5 秒, 再看日志 ==="
dmesg -c >/dev/null 2>&1
rm -f /tmp/f4k.raw
timeout 8 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=2 --stream-to=/tmp/f4k.raw 2>&1 | tail -6
echo "size=$(stat -c %s /tmp/f4k.raw 2>/dev/null || echo 0)"
echo "--- 本次流期间的 dmesg ---"
dmesg 2>&1 | tail -30

echo ""
echo "=== C) log-status ==="
v4l2-ctl -d /dev/video22 --log-status 2>&1 | head -25
