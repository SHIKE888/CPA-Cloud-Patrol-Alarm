#!/bin/sh
API=http://127.0.0.1:9012
curl -s -m 5 -X POST -H 'Content-Type: application/json' \
  -d '{"brightness": 0, "contrast": 1.0}' $API/api/params >/dev/null
curl -s -m 5 -X POST -H 'Content-Type: application/json' \
  -d '{"cam_gain_db": 4.8}' $API/api/fpga >/dev/null
sleep 0.5
curl -s -m 5 $API/api/params | tr ',' '\n' | grep -E 'brightness|contrast'
curl -s -m 5 $API/api/fpga | tr ',' '\n' | grep 'cam_gain_db'
