#!/bin/sh
for k in 1 2 3 4 5 6; do
    st=$(systemctl is-active mipi-webstream)
    printf '  t=%ds  %s\n' "$((k * 10))" "$st"
    [ "$st" = "active" ] && break
    sleep 10
done
echo "--- 参数 ---"
curl -s --max-time 6 http://localhost:9012/api/params | head -c 260
echo
echo "--- 当前输出尺寸 ---"
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"' | head -4
echo "--- 快照 ---"
curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/e.jpg
ls -l /tmp/e.jpg 2>/dev/null
