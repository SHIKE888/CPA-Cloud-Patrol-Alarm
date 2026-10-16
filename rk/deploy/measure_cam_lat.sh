#!/bin/bash
# 实测: 改一次参数后, AE 链路要走多久才完成 (CAM_BUSY 何时回落, CAM_WR_CNT 何时 +1)
B=http://127.0.0.1:9012

echo "改参数前:"
curl -s -m 8 $B/api/fpga | grep -o '"CAM_WR_CNT": [0-9]*\|"CAM_BUSY": [0-9]*' | tr '\n' ' '
echo

echo "--> 写入 cam_exp_ms=8.0"
curl -s -m 15 -X POST -H 'Content-Type: application/json' -d '{"cam_exp_ms":8.0}' $B/api/fpga | grep -o '"message": "[^"]*"'

t0=$(date +%s.%N)
for i in $(seq 1 120); do
  s=$(curl -s -m 3 $B/api/fpga)
  w=$(echo "$s" | grep -o '"CAM_WR_CNT": [0-9]*' | grep -o '[0-9]*$')
  b=$(echo "$s" | grep -o '"CAM_BUSY": [0-9]*' | grep -o '[0-9]*$')
  t1=$(date +%s.%N)
  el=$(echo "$t1 - $t0" | bc)
  printf "  t=%6.3fs  CAM_BUSY=%s  CAM_WR_CNT=%s\n" "$el" "$b" "$w"
  if [ "$b" = "0" ] && [ "$i" -gt 3 ]; then
    echo "  => busy 回落, 总耗时 ${el}s"
    break
  fi
done
