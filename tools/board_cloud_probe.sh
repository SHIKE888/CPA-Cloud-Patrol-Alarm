#!/bin/sh
S=http://<SERVER_DOMAIN>
echo "=== /api/health_open ==="
curl -s --max-time 8 "$S/api/health_open" | head -c 400
echo
echo "=== /api/stats ==="
curl -s --max-time 8 "$S/api/stats" | head -c 800
echo
echo "=== /api/state ==="
curl -s --max-time 8 "$S/api/state" | head -c 900
echo
echo "=== 板端到云端的连通性 ==="
curl -s -o /dev/null -w "  HTTP %{http_code}  connect=%{time_connect}s total=%{time_total}s\n" \
     --max-time 8 "$S/api/health_open"
