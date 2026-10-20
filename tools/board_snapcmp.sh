#!/bin/sh
# 连抓 N 张快照比 md5 —— 相同说明原始帧根本没更新(画面冻结)。
# JPEG 编码是确定性的, 同输入必同输出, 所以 md5 相同 == 原始帧相同。
N=${1:-3}
U="http://localhost:9012/snapshot.jpg?full=1&w=640&q=70"
i=1
while [ $i -le $N ]; do
    curl -s --max-time 6 "$U" -o /tmp/sc$i.jpg
    sz=$(wc -c < /tmp/sc$i.jpg 2>/dev/null)
    echo "  snap$i: ${sz} bytes"
    i=$((i + 1))
    sleep 0.7
done
echo "--- md5 ---"
md5sum /tmp/sc*.jpg 2>/dev/null
echo "--- 判定 ---"
u=$(md5sum /tmp/sc*.jpg 2>/dev/null | awk '{print $1}' | sort -u | wc -l)
n=$(ls /tmp/sc*.jpg 2>/dev/null | wc -l)
if [ "$u" -le 1 ]; then
    echo "  ❌ 全部相同 ($n 张, $u 种) -> 原始帧冻结, 画面不会动"
else
    echo "  ✅ 有 $u 种不同 (共 $n 张) -> 画面在更新"
fi
