#!/bin/sh
echo "== switch to 1080p60"
curl -s --max-time 8 -X POST -H "Content-Type: application/json" \
  -d '{"id":"1080p60"}' http://127.0.0.1:9012/api/mode | head -c 400
echo
sleep 8
echo "== after restart"
curl -s --max-time 5 http://127.0.0.1:9012/api/sys | head -c 400
echo
echo "== back to 4k25"
curl -s --max-time 8 -X POST -H "Content-Type: application/json" \
  -d '{"id":"4k25"}' http://127.0.0.1:9012/api/mode | head -c 400
echo
sleep 8
curl -s --max-time 5 http://127.0.0.1:9012/api/sys | head -c 400
echo
