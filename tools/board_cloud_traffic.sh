#!/bin/sh
P=$(pgrep -f cloud_agent.py | head -1)
echo "=== cloud_agent pid=$P ==="
if [ -z "$P" ]; then echo "  进程不存在!"; exit 1; fi

echo "=== /proc/$P/io 的 write_bytes 采样 (每 6s, 应持续增长) ==="
i=1
prev=0
while [ $i -le 4 ]; do
    w=$(awk '/^write_bytes/{print $2}' /proc/$P/io 2>/dev/null)
    if [ "$prev" != "0" ] && [ -n "$w" ]; then
        echo "  t=$((i*6))s  write_bytes=$w  (+$((w - prev)))"
    else
        echo "  t=$((i*6))s  write_bytes=$w"
    fi
    prev=$w
    sleep 6
    i=$((i + 1))
done

echo "=== 当前 TCP 连接 (到云端) ==="
ss -tnp 2>/dev/null | grep "pid=$P" | head -5
[ -z "$(ss -tnp 2>/dev/null | grep "pid=$P")" ] && echo "  (无活动连接, 推送间隔中)"

echo "=== 用板端 token 试一次健康检查 ==="
T=$(cat /root/rk/cloud/token 2>/dev/null)
echo "  token 长度=${#T}"
curl -s --max-time 8 -H "Authorization: Bearer $T" \
     http://<SERVER_DOMAIN>/api/health_open | head -c 300
echo
curl -s --max-time 8 -H "X-Token: $T" \
     http://<SERVER_DOMAIN>/api/health_open | head -c 300
echo
echo "=== 进程运行时长 / 重启次数 ==="
systemctl show cloud-agent -p ActiveEnterTimestamp -p NRestarts --value
