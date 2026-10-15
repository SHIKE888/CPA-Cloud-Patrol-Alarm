#!/bin/bash
# 4K 切换验证: 关键看 RK 侧 /dev/video22 的格式有没有跟着变
B=http://127.0.0.1:9012
api() { curl -s -m 25 "$@"; }
fmt() { v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | grep -E 'Width/Height' | tr -s ' '; }
st() {
  curl -s -m 10 $B/api/status \
    | grep -o '"width": [0-9]*\|"height": [0-9]*\|"fps": [0-9.]*' | head -3 | tr '\n' ' '
  echo
}

echo "=== 0. 初始 ==="; printf "  video22: "; fmt; printf "  status : "; st

echo
echo "=== 1. 切 4k15 (force=true: FPS_DIV 未实现, 实际仍是满速 30fps) ==="
api -X POST -H 'Content-Type: application/json' -d '{"id":"4k15","force":true}' $B/api/mode; echo
sleep 9
printf "  video22: "; fmt
printf "  status : "; st

echo
echo "=== 2. 抓帧看尺寸 ==="
curl -s -m 25 --output /root/k4_snap.jpg $B/snapshot.jpg
ls -l /root/k4_snap.jpg
file /root/k4_snap.jpg

echo
echo "=== 3. 采集日志 (v4l2 set-fmt 结果) ==="
grep -a "v4l2-ctl set-fmt" /tmp/webstream.log | tail -8
echo "  --- 日志尾部 ---"
tail -8 /tmp/webstream.log

echo
echo "=== 4. 切回 1080p60 ==="
api -X POST -H 'Content-Type: application/json' -d '{"id":"1080p60"}' $B/api/mode; echo
sleep 7
printf "  video22: "; fmt
printf "  status : "; st
