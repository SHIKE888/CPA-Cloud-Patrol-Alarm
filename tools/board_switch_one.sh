#!/bin/sh
# 单次切换验证 (等 60 秒, 覆盖 start.sh 的 25s 等待)
API=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

target=$1      # 1080p60 | 4k25
tw=$2; th=$3

echo "=== 切到 $target ==="
curl -s -m 20 -X POST -H 'Content-Type: application/json' \
     -d "{\"id\":\"$target\"}" $API/api/mode >/dev/null 2>&1

i=0
while [ $i -lt 70 ]; do
  sleep 2
  i=$((i + 2))
  r=$(curl -s -m 3 $API/api/status 2>/dev/null)
  [ -z "$r" ] && continue
  if echo "$r" | $PY -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(1)
ok = (d.get('width')==$tw and d.get('height')==$th and d.get('fps',0)>1)
if ok: print('  第 %ds: OK %dx%d fps=%.1f' % ($i, $tw, $th, d['fps']))
raise SystemExit(0 if ok else 1)
"; then
    echo "  ✔ 切换成功"
    exit 0
  fi
done
echo "  ✗ 70 秒内没恢复"
curl -s -m 4 $API/api/status | head -c 150; echo
exit 1
