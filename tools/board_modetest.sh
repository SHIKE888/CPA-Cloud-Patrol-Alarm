#!/bin/sh
# 用法: sh /tmp/mt.sh          -> 列出模式
#       sh /tmp/mt.sh 4k25     -> 切到 4k25
API=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python
if [ -z "$1" ]; then
  curl -s -m 5 $API/api/modes | $PY -c "
import sys, json
d = json.load(sys.stdin)
print('current:', (d.get('current') or {}).get('id'))
for m in d.get('resolutions', []):
    print(' ', m.get('id'), m.get('label'), 'impl=%s' % m.get('impl'))
"
else
  echo "-> $1"
  curl -s -m 8 -X POST -H 'Content-Type: application/json' \
    -d "{\"id\": \"$1\"}" $API/api/mode
  echo
fi
