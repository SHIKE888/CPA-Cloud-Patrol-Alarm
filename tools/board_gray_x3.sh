#!/bin/sh
for i in 1 2 3; do
  echo "--- run $i"
  /opt/miniforge3/envs/mlk-ov/bin/python /tmp/gray_hw.py 2>/dev/null | tail -4
done
curl -s -m 5 http://127.0.0.1:9012/api/sys | grep -o '"jpeg": {[^}]*}'
