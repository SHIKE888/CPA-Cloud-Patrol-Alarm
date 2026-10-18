#!/bin/sh
echo "== 切到硬件编码"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":true}' \
  http://127.0.0.1:9012/api/jpeg; echo
echo "== 关掉 AI 叠加(否则硬件快路不生效)"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"source":"raw"}' \
  http://127.0.0.1:9012/api/ai > /dev/null
sleep 4
echo "== 4K 下状态"
curl -s -m 5 http://127.0.0.1:9012/api/sys | sed 's/.*"fps": \([0-9.]*\).*"capture_to_ready": \([0-9.]*\).*"jpeg": {\([^}]*\)}.*/fps=\1 lat=\2 jpeg={\3}/'
echo "== 日志尾部"
tail -6 /tmp/mipi_start.log | grep -E 'jpeg|编码' || true
echo "== 切回软件编码"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"hw":false}' \
  http://127.0.0.1:9012/api/jpeg; echo
sleep 2
curl -s -m 5 http://127.0.0.1:9012/api/sys | grep -o '"jpeg": {[^}]*}'
