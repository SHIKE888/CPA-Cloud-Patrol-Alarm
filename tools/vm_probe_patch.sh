#!/bin/bash
SDK="$HOME/mlk-sdk-3576-v1.1.0"
K="$SDK/kernel-6.1"
D="$K/drivers/media/i2c/milianke_mipi.c"

echo "=== 1. 待改处原文 (guest 现行 stock) 行 128~150 ==="
sed -n '128,150p' "$D" | cat -n | sed 's/^/   /'

echo
echo "=== 2. 模式相关原文 行 45~70 ==="
sed -n '45,70p' "$D"

echo
echo "=== 3. SDK 原始 tarball 能否作为纯净回溯源 ==="
ls -la "$HOME/mlk-sdk-3576-v1.1.0.tar.gz"
echo "--- 在 tarball 里找 milianke_mipi.c (最多等 45 秒) ---"
timeout 45 tar -tzf "$HOME/mlk-sdk-3576-v1.1.0.tar.gz" 2>/dev/null | grep -m2 'milianke_mipi.c' || echo "(45 秒内没扫到, 说明该文件在包尾, 全量扫描需数分钟)"

echo
echo "=== 4. 磁盘剩余(给备份用) ==="
df -h "$HOME" | tail -1
