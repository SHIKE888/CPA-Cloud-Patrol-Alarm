#!/bin/sh
# 双跳切换: 先跳到相反模式, 再跳到目标 —— 强制 FPGA 重下 sensor 初始化表
# 用法: sh /tmp/dbl.sh 0|2   (0=1080p60, 2=4K25)
TARGET=${1:-0}
if [ "$TARGET" = "0" ]; then
  OTHER=2; W=1920; H=1080; MODE=1080
else
  OTHER=0; W=3840; H=2160; MODE=4k
fi

pkill -9 -f 'mipi_webstream\.py' 2>/dev/null
sleep 2
echo "dbl: 0xE0 <- $OTHER (过渡)"
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 $OTHER 2>&1 | tail -1
sleep 3
echo "dbl: 0xE0 <- $TARGET (目标)"
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 $TARGET 2>&1 | tail -1
sleep 5
bash /root/start.sh $MODE >/tmp/dbl_start.log 2>&1
sleep 20
curl -s -m 5 http://127.0.0.1:9012/api/status | head -c 130
echo
curl -s -m 5 http://127.0.0.1:9012/api/sys | /opt/miniforge3/envs/mlk-ov/bin/python -c "
import sys, json
d = json.load(sys.stdin)
print('clients=%s frame_id=%s fps=%s' % (d.get('clients'), d.get('frame_id'), d.get('fps')))
"
echo "select timeout: $(grep -c 'select() timeout' /tmp/mipi_start.log)"
