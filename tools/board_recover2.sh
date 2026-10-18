#!/bin/sh
# 一键恢复: 清掉所有 web 实例 -> 清锁 -> start.sh 重新拉起
# 用法: sh /tmp/rcv2.sh [1080|4k]
MODE=${1:-1080}
pkill -9 -f 'mipi_webstream\.py' 2>/dev/null
sleep 2
rm -f /tmp/mipi_webstream.lock
echo "残留 web: $(pgrep -c -f 'mipi_webstream' || echo 0)"

bash /root/start.sh "$MODE" >/tmp/recover_$MODE.log 2>&1
sleep 18

echo "web 实例数: $(pgrep -c -f 'mipi_webstream' || echo 0)"
curl -s -m 6 http://127.0.0.1:9012/api/status | head -c 130
echo
curl -s -m 6 http://127.0.0.1:9012/api/sys | /opt/miniforge3/envs/mlk-ov/bin/python -c "
import sys, json
d = json.load(sys.stdin)
print('clients=%s frame_id=%s fps=%s' % (d.get('clients'), d.get('frame_id'), d.get('fps')))
"
echo "select timeout: $(grep -c 'select() timeout' /tmp/mipi_start.log)"
df -h / | tail -1
