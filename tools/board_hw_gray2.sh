#!/bin/sh
show() {
  curl -s -m 6 http://127.0.0.1:9012/api/sys > /tmp/ss.json
  /opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import json
d = json.load(open("/tmp/ss.json"))
print("  fps=%s  cap=%sx%s  jpeg(want=%s active=%s)  cpu=%s%%"
      % (d["fps"], d["capture"]["width"], d["capture"]["height"],
         d["jpeg"]["want_hw"], d["jpeg"]["active"], d["cpu"]["total"]))
PY
}
echo "== before"; show
echo "== AI -> raw (硬件快路需要)"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"source":"raw"}' \
  http://127.0.0.1:9012/api/ai >/dev/null
echo "== hw on"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":true}' \
  http://127.0.0.1:9012/api/jpeg >/dev/null
sleep 6; show
echo "== 扫 15s 灰帧/截断"
/opt/miniforge3/envs/mlk-ov/bin/python /tmp/gray_hw.py
echo "== hw off 对照"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":false}' \
  http://127.0.0.1:9012/api/jpeg >/dev/null
sleep 4; show
/opt/miniforge3/envs/mlk-ov/bin/python /tmp/gray_hw.py
