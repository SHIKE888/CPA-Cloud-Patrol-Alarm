#!/bin/sh
# 反复切模式, 每次等 20 秒看有没有真的出帧
API=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python
for id in 1080p60 4k25 1080p60 4k25; do
  echo "=== 切到 $id ==="
  curl -s -m 20 -X POST -H 'Content-Type: application/json' \
       -d "{\"id\":\"$id\"}" $API/api/mode | head -c 300
  echo
  i=0
  while [ $i -lt 20 ]; do
    sleep 1
    r=$(curl -s -m 3 $API/api/status 2>/dev/null)
    if [ -n "$r" ]; then
      echo "$r" | $PY -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if d.get('fps', 0) > 1:
    print('  OK  %dx%d  fps=%.1f' % (d['width'], d['height'], d['fps']))
    raise SystemExit(0)
raise SystemExit(1)
" && break
    fi
    i=$((i + 1))
  done
  [ $i -ge 20 ] && echo "  ✗ 20 秒内没出帧 (卡死)"
done
echo "=== 最终 ==="
curl -s -m 5 $API/api/status | head -c 130
echo
