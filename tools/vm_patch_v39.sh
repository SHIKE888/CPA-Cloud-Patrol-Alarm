#!/bin/bash
set -e
DRV=/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1/drivers/media/i2c/milianke_mipi.c
cp -f "$DRV" "$DRV.bak_v39_$(date +%s)"
# V39: 4K25 vblank 704(旧 VTC 2060x2864) -> 65(当前 VTC 2652x2225)
sed -i 's/147500000ULL, 704, "3840x2160@25"/147500000ULL, 65, "3840x2160@25"/' "$DRV"
echo "--- 4K25 entry ---"
grep -n '3840x2160@25' "$DRV"
echo "--- 4K30 entry ---"
grep -n '3840x2160@30' "$DRV"
echo "--- colorspace (确认没被覆盖) ---"
grep -n 'V4L2_COLORSPACE_REC709' "$DRV"
