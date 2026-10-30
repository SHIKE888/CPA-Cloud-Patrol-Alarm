#!/bin/sh
# 0x5408 深度验收: MIPI 错误稳定值 + buffer FFD8
echo "=== MIPI err delta over 4s (settled) ==="
c1=$(dmesg | grep -c MIPI_CSI2)
sleep 4
c2=$(dmesg | grep -c MIPI_CSI2)
echo "  delta=$((c2 - c1))  (total=$c2)"

echo
echo "=== recent MIPI err types (last 2000 lines) ==="
dmesg | tail -2000 | grep -oE "\((ecc2|ecc|crc|err id)[^)]*\)" | sort | uniq -c | sort -rn | head -8

echo
echo "=== raw buffer FFD8 ==="
systemctl stop mipi-webstream
sleep 1.5
timeout 40 /opt/miniforge3/envs/mlk-ov/bin/python /tmp/pbs.py 2>&1 | grep -vE '^\[ WARN' | head -26
systemctl start mipi-webstream
sleep 1
echo
echo "web=$(systemctl is-active mipi-webstream)"
