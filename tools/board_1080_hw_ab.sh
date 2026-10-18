#!/bin/sh
stat() {
  curl -s -m 5 http://127.0.0.1:9012/api/sys > /tmp/s1.json
  sleep 2
  curl -s -m 5 http://127.0.0.1:9012/api/sys > /tmp/s2.json
  /opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import json
d = json.load(open("/tmp/s2.json"))
print("  cpu=%s%%  fps=%s  lat=%sms  hw_active=%s  size=%s"
      % (d["cpu"]["total"], d["fps"], d["latency_ms"]["capture_to_ready"],
         d["jpeg"]["active"], d["jpeg"]["size"]))
PY
}
echo "== 1080p60 software"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":false}' http://127.0.0.1:9012/api/jpeg >/dev/null
sleep 3; stat
echo "== 1080p60 hardware"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":true}' http://127.0.0.1:9012/api/jpeg >/dev/null
sleep 4; stat
echo "== switch to 4K25 (check the flag survives restart)"
curl -s -m 8 -X POST -H "Content-Type: application/json" -d '{"id":"4k25"}' http://127.0.0.1:9012/api/mode >/dev/null
sleep 11; stat
