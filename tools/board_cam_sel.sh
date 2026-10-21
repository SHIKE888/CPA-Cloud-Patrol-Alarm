#!/bin/sh
# 通过 /api/fpga 切 CSI 通道 (RX_SEL), 并检查 0xDB 的其它位有没有被误清
g() { printf '%s' "$(i2cget -y 9 0x40 $1 2>/dev/null)"; }
echo "初始 0xDB = $(g 0xdb)   (期望 0x05 = cam1 + mark_en)"

for C in 0 1; do
    echo "--- 切到 cam$C ---"
    curl -s --max-time 5 -X POST -H 'Content-Type: application/json' \
         -d "{\"RX_SEL\":$C}" http://localhost:9012/api/fpga \
        | tr ',' '\n' | grep -E '"RX_SEL"|"MARK_EN"|"DUAL_EN"|"write_ok"|"message"'
    echo "  寄存器 0xDB = $(g 0xdb)"
    sleep 1
done

echo "最终 0xDB = $(g 0xdb)   (期望 0x05, mark_en 位必须还在)"
