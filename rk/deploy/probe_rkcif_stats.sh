#!/bin/sh
echo "=== 1) 找 rkcif/csi2 统计入口 ==="
ls -d /proc/rkcif* /sys/kernel/debug/rkcif* /sys/kernel/debug/*cif* /sys/kernel/debug/*csi* 2>/dev/null
mount | grep -i debug
echo "--- /proc 里的相关项 ---"
ls /proc | grep -iE "cif|csi|mipi|isp" 2>/dev/null

echo ""
echo "=== 2) 打开 debugfs 再看 ==="
mount -t debugfs none /sys/kernel/debug 2>/dev/null
ls -d /sys/kernel/debug/*cif* /sys/kernel/debug/*csi* /sys/kernel/debug/*dphy* 2>/dev/null
find /sys/kernel/debug -maxdepth 2 -iname "*cif*" -o -maxdepth 2 -iname "*csi*" 2>/dev/null | head -20

echo ""
echo "=== 3) 关键: 先看启动以来有没有收到过包 (清空前) ==="
dmesg | grep -iE "rkcif.*(err|error|timeout|overflow|size|info)|csi2.*(err|error)|dphy.*(err|error)" | tail -20

echo ""
echo "=== 4) 用 debug 打开 rkcif 日志再抓一次 ==="
D=$(find /sys/kernel/debug -maxdepth 3 -type d -iname "*rkcif*" 2>/dev/null | head -1)
echo "rkcif debug 目录: $D"
if [ -n "$D" ]; then ls -l "$D"; fi

echo ""
echo "=== 5) FPGA 侧帧计数 + 行组数 现读 ==="
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -E "帧计数|0xD4|0xD5|0xE0"
echo -n "  0xD4="; python3 /root/rk/deploy/fpga_cfg.py get 0xD4 2>&1 | tail -1
echo -n "  0xD5="; python3 /root/rk/deploy/fpga_cfg.py get 0xD5 2>&1 | tail -1
