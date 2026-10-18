#!/bin/sh
# 专门测 "4K -> 1080p" 这一条（用户报的卡死路径）
API=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

wait_ok() {
  tw=$1; th=$2; label=$3
  i=0
  while [ $i -lt 45 ]; do
    r=$(curl -s -m 3 $API/api/status 2>/dev/null)
    if [ -n "$r" ]; then
      echo "$r" | $PY -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if d.get('width') == $tw and d.get('height') == $th and d.get('fps', 0) > 1:
    print('  OK  %dx%d fps=%.1f' % ($tw, $th, d['fps']))
    raise SystemExit(0)
raise SystemExit(1)
" && return 0
    fi
    i=$((i + 1)); sleep 1
  done
  echo "  ✗ $label 45 秒内没恢复"
  curl -s -m 4 $API/api/status | head -c 160; echo
  return 1
}

echo "=== 1) 切到 4K25 ==="
curl -s -m 20 -X POST -H 'Content-Type: application/json' \
     -d '{"id":"4k25"}' $API/api/mode | head -c 160; echo
wait_ok 3840 2160 "4K"

echo "=== 2) 4K -> 1080p60 (关键测试) ==="
curl -s -m 20 -X POST -H 'Content-Type: application/json' \
     -d '{"id":"1080p60"}' $API/api/mode | head -c 160; echo
wait_ok 1920 1080 "1080p"

echo "=== 3) 再切回 4K25 ==="
curl -s -m 20 -X POST -H 'Content-Type: application/json' \
     -d '{"id":"4k25"}' $API/api/mode | head -c 160; echo
wait_ok 3840 2160 "4K-again"

echo "=== 最终 ==="
curl -s -m 5 $API/api/status | head -c 140; echo
echo "select timeout: $(grep -c 'select() timeout' /tmp/mipi_start.log)"
