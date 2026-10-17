#!/bin/sh
sys() { curl -s -m 6 http://127.0.0.1:9012/api/sys; echo; }
mode() {
  curl -s -m 8 -X POST -H "Content-Type: application/json" \
    -d "{\"id\":\"$1\"}" http://127.0.0.1:9012/api/mode > /dev/null
  sleep 9
}
echo "== params"
curl -s -m 5 http://127.0.0.1:9012/api/params; echo
echo "== current sys"
sys
echo "== -> 1080p60"
mode 1080p60
sys
echo "== -> 4k25"
mode 4k25
sys
echo "== dmesg vblank/err (tail)"
dmesg | tail -8
