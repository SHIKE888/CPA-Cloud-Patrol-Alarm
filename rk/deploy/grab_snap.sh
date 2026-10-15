#!/bin/bash
# 确保 web 服务在跑, 抓一帧画面 + 打印状态
# 用法: grab_snap.sh [输出路径]
OUT=${1:-/root/snap.jpg}

if ! pgrep -f mipi_webstream.py > /dev/null; then
    echo "web 未运行, 启动中..."
    cd /root/rk/web
    nohup ./start_webstream.sh > /tmp/webstream.log 2>&1 &
    sleep 10
fi

echo "=== 内核 ==="
cat /proc/version

echo
echo "=== api/status ==="
curl -s -m 8 http://127.0.0.1:9012/api/status
echo

echo
echo "=== 抓帧 ==="
curl -s -m 15 --output "$OUT" http://127.0.0.1:9012/snapshot.jpg
ls -l "$OUT"

echo
echo "=== web 日志尾部 (看有无读帧失败) ==="
tail -8 /tmp/webstream.log

echo
echo "=== FPGA 状态 ==="
curl -s -m 8 http://127.0.0.1:9012/api/fpga --output /tmp/fpga.json
grep -o '"FRAME_CNT": [0-9]*' /tmp/fpga.json
grep -o '"HEARTBEAT": [0-9]*' /tmp/fpga.json
grep -o '"CAM_ID": [0-9]*' /tmp/fpga.json
