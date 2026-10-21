#!/bin/sh
echo "=== 等 active ==="
for k in 1 2 3 4 5 6 7 8; do
    st=$(systemctl is-active mipi-webstream)
    [ "$st" = "active" ] && { echo "  active (${k}0s)"; break; }
    printf '  %s...\n' "$st"; sleep 10
done
sleep 8

echo "=== 单目基线 ==="
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"|"fps"' | head -3

echo "=== 开双目演示 ==="
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":1,"dual_demo":1}' http://localhost:9012/api/params > /dev/null
sleep 8
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"|"fps"' | head -3

echo "=== 回单目 ==="
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":0,"dual_demo":0}' http://localhost:9012/api/params > /dev/null
sleep 5
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"|"fps"' | head -3

echo "=== CPU 占用 (双目 3840x1080x30 软编是否扛得住) ==="
top -b -n 1 -p "$(pgrep -f mipi_webstream | head -1)" 2>/dev/null | tail -2
