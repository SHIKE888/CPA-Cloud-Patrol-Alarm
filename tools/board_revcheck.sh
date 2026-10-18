#!/bin/sh
API=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python
echo "== 初始 rev =="
curl -s -m 5 $API/api/sys | $PY -c "import sys,json; print(json.load(sys.stdin).get('rev'))"
echo "== 改一个画面参数 =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -d '{"brightness": 12}' $API/api/params >/dev/null
curl -s -m 5 $API/api/sys | $PY -c "import sys,json; print(json.load(sys.stdin).get('rev'))"
echo "== 改摄像头曝光 =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -d '{"cam_gain_db": 6.0}' $API/api/fpga >/dev/null
curl -s -m 5 $API/api/sys | $PY -c "import sys,json; print(json.load(sys.stdin).get('rev'))"
echo "== 改 AI 参数 =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -d '{"det_conf": 0.4}' $API/api/ai >/dev/null
curl -s -m 5 $API/api/sys | $PY -c "import sys,json; print(json.load(sys.stdin).get('rev'))"
echo "== 复原 =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -d '{"brightness": 0}' $API/api/params >/dev/null
curl -s -m 5 -X POST -H 'Content-Type: application/json' -d '{"det_conf": 0.35}' $API/api/ai >/dev/null
echo done
