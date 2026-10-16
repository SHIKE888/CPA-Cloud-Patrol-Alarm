#!/bin/bash
# 参数下发链路修复的验收测试 (烧录新 bit 之后跑)
#
# 关键回归点:
#   A) CAM_WR_CNT 必须**跟着涨**  —— 改之前恒为 2 (看门狗 1ms 太短, 每轮都提前放弃)
#   B) CAM_BUSY 要能看到 ~2.7ms 的忙 —— 改之前只高 1.0ms
#   C) 连续改参 20 次不能卡死、不能丢 —— 改之前请求会被整拍漏掉
#   D) 曝光/增益/EV 的方向和幅度都要对
B=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

st() {
  curl -s -m 8 $B/api/fpga > /tmp/f.json
  printf "  CAM_WR_CNT=%-3s CAM_BUSY=%s  exp=%sms gain=%sdB ev=%s\n" \
    "$(grep -o '"CAM_WR_CNT": [0-9]*' /tmp/f.json | grep -o '[0-9]*$')" \
    "$(grep -o '"CAM_BUSY": [0-9]*' /tmp/f.json | grep -o '[0-9]*$')" \
    "$(grep -o '"cam_exp_ms": [0-9.]*' /tmp/f.json | grep -o '[0-9.]*$')" \
    "$(grep -o '"cam_gain_db": [0-9.]*' /tmp/f.json | grep -o '[0-9.]*$')" \
    "$(grep -o '"ev": [-0-9]*' /tmp/f.json | grep -o '[-0-9]*$')"
}

wr_cnt() { grep -o '"CAM_WR_CNT": [0-9]*' /tmp/f.json | grep -o '[0-9]*$'; }

wr() {
  printf "  写入 %-46s -> " "$1"
  curl -s -m 15 -X POST -H 'Content-Type: application/json' -d "$1" $B/api/fpga \
    | grep -o '"message": "[^"]*"'
}

mean() {
  curl -s -m 15 --output /tmp/v.jpg $B/snapshot.jpg
  $PY - <<'EOF'
import cv2
i = cv2.imread('/tmp/v.jpg', cv2.IMREAD_GRAYSCALE)
print("    亮度=%.1f  (min %d max %d)" % (i.mean(), i.min(), i.max()) if i is not None else "    !! 没抓到帧")
EOF
}

echo "=============================================================="
echo " 0. 基线"
echo "=============================================================="
st; mean

echo
echo "=============================================================="
echo " 1. 曝光 A/B"
echo "=============================================================="
wr '{"cam_exp_ms":0.5}';  sleep 2; mean; st
wr '{"cam_exp_ms":16.6}'; sleep 2; mean; st

echo
echo "=============================================================="
echo " 2. 增益 A/B"
echo "=============================================================="
wr '{"cam_gain_db":0}';  sleep 2; mean
wr '{"cam_gain_db":30}'; sleep 2; mean
wr '{"cam_gain_db":0}';  sleep 2; mean
wr '{"cam_gain_db":30}'; sleep 2; mean; st

echo
echo "=============================================================="
echo " 3. 曝光补偿 EV (+3 不变黑, -3 变暗)"
echo "=============================================================="
wr '{"ev":0}';  sleep 2; mean
wr '{"ev":3}';  sleep 2; mean
wr '{"ev":-3}'; sleep 2; mean
wr '{"ev":0}';  sleep 2; mean

echo
echo "=============================================================="
echo " 4. ★ 连续改参 20 次压力测试 (核心回归) ★"
echo "=============================================================="
curl -s -m 8 $B/api/fpga > /tmp/f.json
w0=$(wr_cnt)
echo "  起始 CAM_WR_CNT = $w0"
ok=0
for i in $(seq 1 20); do
  ms=$(awk "BEGIN{printf \"%.1f\", 4 + ($i % 12) * 1.0}")
  curl -s -m 15 -X POST -H 'Content-Type: application/json' \
       -d "{\"cam_exp_ms\":$ms}" $B/api/fpga > /tmp/w.json
  printf "  #%-2d 写 exp=%-5s -> %s\n" "$i" "$ms" \
    "$(grep -o '"message": "[^"]*"' /tmp/w.json)"
done
sleep 3
curl -s -m 8 $B/api/fpga > /tmp/f.json
w1=$(wr_cnt)
echo "  结束 CAM_WR_CNT = $w1   (delta = $((w1 - w0)) / 20 次改动)"
echo "  CAM_BUSY = $(grep -o '"CAM_BUSY": [0-9]*' /tmp/f.json | grep -o '[0-9]*$')  (必须是 0)"
if [ "$w1" -gt "$w0" ]; then
  echo "  => ✅ CAM_WR_CNT 在涨, 参数链路是活的"
else
  echo "  => ❌ CAM_WR_CNT 没涨, 请求还是被漏掉了"
fi

echo
echo "=============================================================="
echo " 5. 恢复默认"
echo "=============================================================="
wr '{"cam_exp_ms":16.6,"cam_gain_db":14.4,"ev":0,"wb_r_pct":100,"wb_b_pct":100,"roi_pct":100}'
sleep 2
st; mean
