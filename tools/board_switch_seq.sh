#!/bin/sh
# 4K <-> 1080p 往返测试。每次切换后先固定等 25 秒(切换流程要 ~20s), 再校验。
API=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

check() {
  tw=$1; th=$2; label=$3
  i=0
  while [ $i -lt 20 ]; do
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
  echo "  ✗ $label 没恢复"
  curl -s -m 4 $API/api/status | head -c 150; echo
  echo "  switch.pid: $(cat /tmp/mode_switch.pid 2>/dev/null || echo none)"
  return 1
}

do_switch() {
  id=$1; tw=$2; th=$3
  echo "=== 切到 $id ==="
  curl -s -m 20 -X POST -H 'Content-Type: application/json' \
       -d "{\"id\":\"$id\"}" $API/api/mode >/dev/null 2>&1
  echo "  等待切换完成 (25s) ..."
  sleep 25
  check $tw $th "$id"
}

do_switch 4k25    3840 2160
do_switch 1080p60 1920 1080
do_switch 4k25    3840 2160
do_switch 1080p60 1920 1080

echo "=== 最终 ==="
curl -s -m 5 $API/api/status | head -c 130; echo
echo "heal 次数: $(grep -c '\[heal\]' /tmp/mipi_start.log)"
echo "select timeout: $(grep -c 'select () timeout\|select() timeout' /tmp/mipi_start.log)"
