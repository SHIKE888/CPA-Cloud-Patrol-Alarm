#!/bin/sh
echo "== ai state"
curl -s -m 5 http://127.0.0.1:9012/api/ai | head -c 400; echo
fps() { curl -s -m 6 http://127.0.0.1:9012/api/sys | sed 's/.*"fps": \([0-9.]*\).*"latency_ms": {"capture_to_ready": \([0-9.]*\).*/fps=\1 lat=\2/'; }
echo "== now (ai on?)"; fps
echo "== disable ai"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"enabled":false}' \
  http://127.0.0.1:9012/api/ai > /dev/null
sleep 4; fps
echo "== enable ai"
curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{"enabled":true}' \
  http://127.0.0.1:9012/api/ai > /dev/null
sleep 4; fps
echo "== threads"
ps -o pid,pcpu,nlwp,args -p $(pgrep -f 'mipi_webstream.py' | head -1) 2>/dev/null
