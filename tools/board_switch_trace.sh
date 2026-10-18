#!/bin/sh
echo "== state before"
curl -s -m 5 http://127.0.0.1:9012/api/sys | grep -o '"fps": [0-9.]*' | head -1
echo "== POST mode 1080p60"
curl -s -m 8 -X POST -H "Content-Type: application/json" -d '{"id":"1080p60"}' \
  http://127.0.0.1:9012/api/mode | head -c 200; echo
for i in 1 2 3 4 5 6; do
  sleep 4
  printf "t+%2ds: " $((i*4))
  curl -s -m 5 http://127.0.0.1:9012/api/sys | grep -o '"fps": [0-9.]*\|"active": [a-z]*' | tr '\n' ' '
  echo
done
echo "== log tail"
grep -vE 'RKNN|rknn|dynamic|模型' /tmp/mipi_start.log | tail -10
