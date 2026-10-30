#!/bin/sh
# V54g 验收: 1) MIPI 错误增量  2) buffer 里有没有 FFD8
PY=/opt/miniforge3/envs/mlk-ov/bin/python

echo "=== 1. MIPI error growth over 4s (streaming) ==="
c1=$(dmesg | grep -c "MIPI_CSI2")
sleep 4
c2=$(dmesg | grep -c "MIPI_CSI2")
echo "  before=$c1  after=$c2  delta=$((c2 - c1))"
if [ "$c1" -ge "$c2" ]; then
    echo "  (ring buffer wrapped, delta unreliable)"
fi

echo
echo "=== 2. grab raw buffer and look for JPEG SOI ==="
systemctl stop mipi-webstream
sleep 1.5
timeout 40 $PY /tmp/pbs.py 2>&1 | grep -vE "^\[ WARN" | head -60
systemctl start mipi-webstream
sleep 1
echo
echo "web: $(systemctl is-active mipi-webstream)"
