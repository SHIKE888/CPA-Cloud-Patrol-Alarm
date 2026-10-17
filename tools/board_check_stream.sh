#!/bin/sh
# 1) 用 curl 模拟浏览器长连接
curl -s -m 20 http://127.0.0.1:9012/stream -o /tmp/st_before.bin &
CPID=$!
sleep 3
echo "before bytes: $(stat -c %s /tmp/st_before.bin 2>/dev/null)"

# 2) 触发切模式（服务端会 execv 重启）
curl -s -m 8 -X POST -H "Content-Type: application/json" \
  -d '{"id":"1080p60"}' http://127.0.0.1:9012/api/mode > /tmp/mode_resp.json
echo "mode resp: $(head -c 120 /tmp/mode_resp.json)"

# 3) 老连接应该已经断了
wait $CPID 2>/dev/null
echo "old conn total bytes: $(stat -c %s /tmp/st_before.bin 2>/dev/null)"

# 4) 新连接（模拟页面重连）能否正常出数据
sleep 5
curl -s -m 6 http://127.0.0.1:9012/stream -o /tmp/st_after.bin
echo "new conn bytes: $(stat -c %s /tmp/st_after.bin 2>/dev/null)"

# 5) 切回 4K
curl -s -m 8 -X POST -H "Content-Type: application/json" \
  -d '{"id":"4k25"}' http://127.0.0.1:9012/api/mode > /dev/null
sleep 6
curl -s -m 6 http://127.0.0.1:9012/stream -o /tmp/st_4k.bin
echo "4k new conn bytes: $(stat -c %s /tmp/st_4k.bin 2>/dev/null)"
