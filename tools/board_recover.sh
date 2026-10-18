#!/bin/sh
# 彻底清理 web 实例 + 干净重启到 4K。
# 注意: 必须在脚本里做 pkill —— 直接写在 ssh 命令里会因为命令行包含同样的
#       字符串而把自己一起杀掉。
pkill -9 -f 'mipi_webstream\.py' 2>/dev/null
sleep 2
pkill -9 -f 'rk/web/start_webstream' 2>/dev/null
sleep 1
echo "残留 web 进程数: $(pgrep -c -f 'mipi_webstream' || echo 0)"

python3 /root/rk/deploy/fpga_cfg.py set 0xE0 0 >/dev/null 2>&1
sleep 3
bash /root/start.sh 4k >/tmp/s98.log 2>&1
sleep 18

echo "启动后 web 进程数: $(pgrep -c -f 'mipi_webstream' || echo 0)"
curl -s -m 5 http://127.0.0.1:9012/api/status | head -c 140
echo
curl -s -m 5 http://127.0.0.1:9012/api/sys | /opt/miniforge3/envs/mlk-ov/bin/python -c "
import sys, json
d = json.load(sys.stdin)
print('clients=%s frame_id=%s fps=%s' % (d.get('clients'), d.get('frame_id'), d.get('fps')))
"
echo "select timeout 次数: $(grep -c 'select() timeout' /tmp/mipi_start.log)"
