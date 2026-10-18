#!/bin/sh
# 反复切模式, 每次轮询到"目标分辨率 + 真的在出帧"才算成功
API=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

check() {
  # $1=目标宽 $2=目标高
  curl -s -m 3 $API/api/status 2>/dev/null | $PY -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
ok = (d.get('width') == $1 and d.get('height') == $2 and d.get('fps', 0) > 1)
if ok:
    print('  OK  %dx%d  fps=%.1f' % (d['width'], d['height'], d['fps']))
raise SystemExit(0 if ok else 1)
"
}

for pair in "1080p60 1920 1080" "4k25 3840 2160" "1080p60 1920 1080" "4k25 3840 2160"; do
  set -- $pair
  id=$1; tw=$2; th=$3
  echo "=== 切到 $id ==="
  curl -s -m 20 -X POST -H 'Content-Type: application/json' \
       -d "{\"id\":\"$id\"}" $API/api/mode >/dev/null 2>&1
  i=0
  while [ $i -lt 35 ]; do
    sleep 1
    check $tw $th && break
    i=$((i + 1))
  done
  if [ $i -ge 35 ]; then
    echo "  ✗ 35 秒内没切成功 (卡死)"
    curl -s -m 4 $API/api/status | head -c 160; echo
  fi
done
echo "=== 最终 ==="
curl -s -m 5 $API/api/status | head -c 140
echo
echo "=== 切换日志 ==="
tail -12 /tmp/mode_switch.log 2>/dev/null | grep -E '^\[|RES_MODE|media|已启动|✗' | tail -8
