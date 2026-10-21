#!/bin/sh
# 切通道往返测试: 每次切换后等采集重连, 用快照大小判断有没有画面
snap() {
    curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/sw.jpg
    sz=$(stat -c %s /tmp/sw.jpg 2>/dev/null || echo 0)
    if [ "$sz" -gt 5000 ]; then echo "    有画面 (${sz} 字节)"; else echo "    无画面 (${sz} 字节)"; fi
}

post() {
    curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
         -d "{\"RX_SEL\":$1}" http://localhost:9012/api/fpga \
      | tr ',' '\n' | grep -E '"RX_SEL"|"rx_switched"|"message"' | sed 's/^/    /'
}

echo "=== 起点: cam1 ==="
echo "  0xDB = $(i2cget -y 9 0x40 0xdb)"
snap

echo "=== 切到 cam0 (板上没插模组, 预期无画面) ==="
post 0
echo "  0xDB = $(i2cget -y 9 0x40 0xdb)"
sleep 14
snap

echo "=== 切回 cam1 (预期自动恢复, 不用手动重启) ==="
post 1
echo "  0xDB = $(i2cget -y 9 0x40 0xdb)"
sleep 14
snap

echo "=== 服务状态 ==="
systemctl is-active mipi-webstream
