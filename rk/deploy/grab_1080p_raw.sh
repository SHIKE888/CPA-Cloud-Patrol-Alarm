#!/bin/sh
# 短暂停 web -> 抓 1080p 裸帧 -> 重新起 web
echo "=== 停 web ==="
pkill -f mipi_webstream.py && echo "  已停" || echo "  未运行"
sleep 2

echo "=== 抓 2 帧 1080p ==="
rm -f /tmp/f1080.raw
timeout 12 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=2 --stream-to=/tmp/f1080.raw 2>&1 | tail -4
ls -l /tmp/f1080.raw
dd if=/tmp/f1080.raw of=/tmp/y1080.raw bs=2073600 count=1 2>&1 | tail -1
ls -l /tmp/y1080.raw
md5sum /tmp/y1080.raw

echo ""
echo "=== 重新起 web ==="
cd /root/rk/web || exit 1
nohup bash ./start_webstream.sh /dev/video22 9012 > /tmp/web_start.log 2>&1 &
sleep 8
netstat -lntp 2>/dev/null | grep 9012 && echo "  web 已恢复" || echo "  !! web 未起来"
