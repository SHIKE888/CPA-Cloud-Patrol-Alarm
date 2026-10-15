#!/bin/bash
# web app 摄像头功能测试 (曝光/增益/EV/白平衡/ROI/预处理/只读状态/V4L2 控件)
B=http://127.0.0.1:9012
api() { curl -s -m 12 "$@"; }

echo "=== A. 基线 ==="
api $B/api/fpga --output /tmp/fp0.json
for k in cam_exp_ms cam_gain_db ev wb_r_pct wb_b_pct roi_pct CAM_WR_CNT; do
  printf "  %-11s " "$k"; grep -o "\"$k\": [0-9.-]*" /tmp/fp0.json | head -1
done

echo
echo "=== B. 写入 曝光=8ms 增益=9dB EV=+1 WB_R=120% WB_B=90% ROI=80% ==="
api -X POST -H 'Content-Type: application/json' \
    -d '{"cam_exp_ms":8,"cam_gain_db":9,"ev":1,"wb_r_pct":120,"wb_b_pct":90,"roi_pct":80}' \
    $B/api/fpga --output /tmp/fp1.json
printf "  write_ok = "; grep -o '"write_ok": [a-z]*' /tmp/fp1.json
printf "  message  = "; grep -o '"message": "[^"]*"' /tmp/fp1.json
sleep 1
api $B/api/fpga --output /tmp/fp2.json
echo "  -- 回读 --"
for k in cam_exp_ms cam_gain_db ev wb_r_pct wb_b_pct roi_pct CAM_WR_CNT; do
  printf "  %-11s " "$k"; grep -o "\"$k\": [0-9.-]*" /tmp/fp2.json | head -1
done

echo
echo "=== C. 恢复默认 ==="
api -X POST -H 'Content-Type: application/json' \
    -d '{"cam_exp_ms":16.6,"cam_gain_db":14.4,"ev":0,"wb_r_pct":100,"wb_b_pct":100,"roi_pct":100}' \
    $B/api/fpga --output /dev/null
echo "  done"

echo
echo "=== D. 预处理预设 ==="
for p in orig sobel thresh morph; do
  printf "  %-7s " "$p"
  api -X POST -H 'Content-Type: application/json' -d "{\"preset\":\"$p\"}" $B/api/fpga \
    | grep -o '"message": "[^"]*"'
done
api -X POST -H 'Content-Type: application/json' -d '{"preset":"off"}' $B/api/fpga --output /dev/null
echo "  已关闭预处理"

echo
echo "=== E. 只读状态 ==="
api $B/api/fpga --output /tmp/fp3.json
grep -o '"FRAME_CNT": [0-9]*' /tmp/fp3.json
grep -o '"HEARTBEAT": [0-9]*' /tmp/fp3.json
grep -o '"VER": [0-9]*' /tmp/fp3.json
grep -o '"CAM_ID": [0-9]*' /tmp/fp3.json

echo
echo "=== F. /api/controls (V4L2 硬件参数) ==="
api $B/api/controls | head -c 400
echo
