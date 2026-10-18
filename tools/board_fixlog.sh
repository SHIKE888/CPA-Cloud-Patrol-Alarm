#!/bin/sh
# 1) 抑制内核日志洪水(CSI2 ECC 错误每帧刷屏, 曾把 14G 磁盘写满)
# 2) 干净重启 web
pkill -9 -f 'mipi_webstream\.py' 2>/dev/null
sleep 2
echo "残留 web: $(pgrep -c -f 'mipi_webstream' || echo 0)"

dmesg -n 1            # 只保留 panic 级别, 不再往 syslog 灌错误
sysctl -w kernel.printk="1 4 1 7" >/dev/null 2>&1

python3 /root/rk/deploy/fpga_cfg.py set 0xE0 0 >/dev/null 2>&1
sleep 3
bash /root/start.sh 4k >/tmp/s99.log 2>&1
sleep 18

echo "web 进程数: $(pgrep -c -f 'mipi_webstream' || echo 0)"
curl -s -m 5 http://127.0.0.1:9012/api/status | head -c 130
echo
curl -s -m 5 http://127.0.0.1:9012/api/sys | /opt/miniforge3/envs/mlk-ov/bin/python -c "
import sys, json
d = json.load(sys.stdin)
print('clients=%s frame_id=%s fps=%s' % (d.get('clients'), d.get('frame_id'), d.get('fps')))
"
echo "select timeout: $(grep -c 'select() timeout' /tmp/mipi_start.log)"
echo "syslog 大小: $(ls -lh /var/log/syslog | awk '{print $5}')"
df -h / | tail -1
