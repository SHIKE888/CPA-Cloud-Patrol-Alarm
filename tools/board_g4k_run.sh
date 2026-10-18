#!/bin/sh
curl -s -m 8 -X POST -H "Content-Type: application/json" \
  -d '{"id":"4k25"}' http://127.0.0.1:9012/api/mode | head -c 120
echo
sleep 13
echo "mode reg: $(i2cget -y 9 0x40 0xe0)"
/opt/miniforge3/envs/mlk-ov/bin/python /tmp/g4k.py
echo "--- dmesg"
dmesg | tail -6
