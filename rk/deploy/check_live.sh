#!/bin/bash
# 判断画面是**实时**还是 **dbuf 里最后一帧被反复重发** (RX 死了但 TX 侧还在跑)
#   实时: 三张快照 md5 各不相同
#   冻结: 三张完全一样
B=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

for i in 1 2 3; do
  curl -s -m 20 -o /tmp/live$i.jpg $B/snapshot.jpg
  printf "  第 %d 张  字节=%-8s  帧计数=%s\n" "$i" \
    "$(stat -c %s /tmp/live$i.jpg)" \
    "$(python3 /root/rk/deploy/fpga_cfg.py dump 2>/dev/null | grep '帧计数' | grep -o '[0-9]*$')"
  sleep 2
done

echo "  --- md5 (三张应各不相同才是实时) ---"
md5sum /tmp/live1.jpg /tmp/live2.jpg /tmp/live3.jpg | sed 's/^/  /'

echo "  --- 亮度 ---"
$PY - <<'EOF'
import cv2
for i in (1, 2, 3):
    im = cv2.imread('/tmp/live%d.jpg' % i, cv2.IMREAD_GRAYSCALE)
    print("    live%d.jpg  %s" % (i, ("%.1f" % im.mean()) if im is not None else "NA"))
EOF

echo "  --- 判定 ---"
n=$(md5sum /tmp/live1.jpg /tmp/live2.jpg /tmp/live3.jpg | awk '{print $1}' | sort -u | wc -l)
if [ "$n" = "3" ]; then
  echo "    ✅ 三张全不同 => 画面是**实时**的"
else
  echo "    ❌ 只有 $n 种 => 画面**冻结**(最后一帧被反复重发, RX 已死)"
fi
