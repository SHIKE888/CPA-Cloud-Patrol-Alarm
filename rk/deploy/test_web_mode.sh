#!/bin/bash
# 分辨率/帧率切换测试 (/api/mode)
B=http://127.0.0.1:9012
api() { curl -s -m 20 "$@"; }

st() {
  curl -s -m 10 $B/api/status \
    | grep -o '"width": [0-9]*\|"height": [0-9]*\|"fps": [0-9.]*' | head -3 | tr '\n' ' '
  echo
}
cur() {
  curl -s -m 10 $B/api/modes \
    | grep -o '"current": {[^}]*}' | head -c 220
  echo
}

echo "=== 0. 初始 ==="; cur; printf "  status: "; st

echo
echo "=== 1. 切 1080p30 ==="
api -X POST -H 'Content-Type: application/json' -d '{"id":"1080p30"}' $B/api/mode; echo
sleep 4; printf "  status: "; st

echo
echo "=== 2. 切回 1080p60 ==="
api -X POST -H 'Content-Type: application/json' -d '{"id":"1080p60"}' $B/api/mode; echo
sleep 4; printf "  status: "; st

echo
echo "=== 3. 请求 4k30 (不带 force, 应被带宽校验拦下) ==="
api -X POST -H 'Content-Type: application/json' -d '{"id":"4k30"}' $B/api/mode; echo

echo
echo "=== 4. 切 4k15 (4K 通路验证) ==="
api -X POST -H 'Content-Type: application/json' -d '{"id":"4k15"}' $B/api/mode; echo
sleep 7; printf "  status: "; st; cur

echo
echo "=== 5. 抓 4K 帧 ==="
curl -s -m 20 --output /root/4k_snap.jpg $B/snapshot.jpg
ls -l /root/4k_snap.jpg
file /root/4k_snap.jpg

echo
echo "=== 6. 切回 1080p60 ==="
api -X POST -H 'Content-Type: application/json' -d '{"id":"1080p60"}' $B/api/mode; echo
sleep 5; printf "  status: "; st; cur

echo
echo "=== 7. 采集线程日志(切换相关) ==="
grep -a "分辨率/帧率切换" /tmp/webstream.log | tail -6
echo "--- 日志尾部 ---"
tail -8 /tmp/webstream.log
