#!/bin/sh
curl -s --max-time 6 http://localhost:9012/api/status \
  | tr ',' '\n' | grep -E 'width|height|fps|dual|cam|nomark|pair|single|active'
echo "--- 0xDB = $(i2cget -y 9 0x40 0xdb)"
