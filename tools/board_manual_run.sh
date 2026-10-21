#!/bin/sh
systemctl stop mipi-webstream
sleep 2
echo "=== 手动跑采集 22 秒, 看 stderr ==="
timeout 22 bash /root/rk/deploy/boot_start.sh 2>&1 | head -50
echo "=== 恢复 ==="
systemctl start mipi-webstream
