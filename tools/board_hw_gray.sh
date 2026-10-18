#!/bin/sh
echo "== 确保 4K + 硬件编码"
i2cget -y 9 0x40 0xe0
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":true}' \
  http://127.0.0.1:9012/api/jpeg > /dev/null
sleep 5
curl -s -m 5 http://127.0.0.1:9012/api/sys | grep -o '"jpeg": {[^}]*}'
echo "== 扫 15s 的灰帧/截断帧"
/opt/miniforge3/envs/mlk-ov/bin/python /tmp/gray_hw.py
