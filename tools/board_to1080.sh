#!/bin/sh
curl -s -m 8 -X POST -H "Content-Type: application/json" \
  -d '{"id":"1080p60"}' http://127.0.0.1:9012/api/mode | head -c 120
echo
sleep 10
curl -s -m 5 http://127.0.0.1:9012/api/sys
echo
