#!/bin/bash
# 重启 web 服务 (改完 py/html 后) 并自检新接口
pkill -f mipi_webstream.py
sleep 1
cd /root/rk/web
nohup ./start_webstream.sh > /tmp/webstream.log 2>&1 &
sleep 9

echo "=== 进程 ==="
pgrep -af mipi_webstream.py

echo
echo "=== /api/modes (新接口) ==="
curl -s -m 8 http://127.0.0.1:9012/api/modes
echo

echo
echo "=== /api/status ==="
curl -s -m 8 http://127.0.0.1:9012/api/status
echo

echo
echo "=== 启动日志尾部 ==="
tail -14 /tmp/webstream.log
