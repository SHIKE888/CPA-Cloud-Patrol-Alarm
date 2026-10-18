#!/bin/sh
stat() {
  sleep 2
  curl -s -m 5 http://127.0.0.1:9012/api/sys > /tmp/s2.json
  /opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
import json
d = json.load(open("/tmp/s2.json"))
print("   %4dx%-4d hw=%-5s cpu=%5s%%  fps=%5s  lat=%sms"
      % (d["capture"]["width"], d["capture"]["height"],
         str(d["jpeg"]["active"]), d["cpu"]["total"], d["fps"],
         d["latency_ms"]["capture_to_ready"]))
PY
}
set_hw() { curl -s -m 5 -X POST -H "Content-Type: application/json" -d "{\"hw\":$1}" http://127.0.0.1:9012/api/jpeg >/dev/null; sleep 3; }

echo "== 1080p60"
set_hw false; stat
set_hw true;  stat
echo "== switch 4K25"
curl -s -m 8 -X POST -H "Content-Type: application/json" -d '{"id":"4k25"}' http://127.0.0.1:9012/api/mode >/dev/null
sleep 12
set_hw false; stat
set_hw true;  stat
echo "== leave in software mode"
set_hw false
stat
