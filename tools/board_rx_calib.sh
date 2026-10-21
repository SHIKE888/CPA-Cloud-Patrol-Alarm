#!/bin/sh
echo "=== RX 校准状态 0xD6/0xD7/0xD8 (固定 cam0, 0xDD/DE/DF = cam1) ==="
echo "cam0: mipi=$(i2cget -y 9 0x40 0xd6) delay=$(i2cget -y 9 0x40 0xd7) bestlen=$(i2cget -y 9 0x40 0xd8)"
echo "cam1: mipi=$(i2cget -y 9 0x40 0xdd) delay=$(i2cget -y 9 0x40 0xde) bestlen=$(i2cget -y 9 0x40 0xdf)"
echo "=== 帧率相关 0xD4/0xD5 (每行组数) ==="
echo "0xD4=$(i2cget -y 9 0x40 0xd4) 0xD5=$(i2cget -y 9 0x40 0xd5)"
echo "=== FRAME_CNT 0xB8..0xBB 三遍 ==="
for k in 1 2 3; do
    b0=$(i2cget -y 9 0x40 0xb8); b1=$(i2cget -y 9 0x40 0xb9)
    b2=$(i2cget -y 9 0x40 0xba); b3=$(i2cget -y 9 0x40 0xbb)
    echo "  FRAME_CNT = $((b3 * 16777216 + b2 * 65536 + b1 * 256 + b0))"
    sleep 2
done
echo "=== RK 侧 rkcif 错误计数 ==="
cat /sys/kernel/debug/rkcif*/err_state 2>/dev/null | head -20 || \
  echo "  (无 err_state 节点)"
echo "=== dmesg 尾部 (MIPI/CSI 报错) ==="
dmesg | tail -25 | grep -iE 'csi|mipi|cif|dphy|ecc|crc' || dmesg | tail -12
