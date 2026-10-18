#!/bin/sh
stat() {
  curl -s -m 5 http://127.0.0.1:9012/api/sys > /tmp/s1.json
  sleep 2
  curl -s -m 5 http://127.0.0.1:9012/api/sys > /tmp/s2.json
  /opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import json
d = json.load(open("/tmp/s2.json"))
print("  cpu=%s%%  fps=%s  lat=%sms  jpeg_active=%s"
      % (d["cpu"]["total"], d["fps"],
         d["latency_ms"]["capture_to_ready"], d["jpeg"]["active"]))
PY
}
echo "== 4K25 软件编码"; curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":false}' http://127.0.0.1:9012/api/jpeg >/dev/null; sleep 3; stat
echo "== 4K25 硬件编码"; curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":true}'  http://127.0.0.1:9012/api/jpeg >/dev/null; sleep 4; stat
echo "== 切 1080p60 硬件编码"
curl -s -m 8 -X POST -H "Content-Type: application/json" -d '{"id":"1080p60"}' http://127.0.0.1:9012/api/mode >/dev/null
sleep 10; curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"source":"raw"}' http://127.0.0.1:9012/api/ai >/dev/null; sleep 3; stat
echo "== 1080p60 软件编码"; curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":false}' http://127.0.0.1:9012/api/jpeg >/dev/null; sleep 3; stat
echo "== 回 4K25 软件编码"
curl -s -m 8 -X POST -H "Content-Type: application/json" -d '{"id":"4k25"}' http://127.0.0.1:9012/api/mode >/dev/null
sleep 10; stat
