#!/bin/sh
echo "=== cloud 相关进程 ==="
ps aux | grep -iE 'cloud|agent' | grep -v grep | cut -c1-150
echo
echo "=== pid 1958 是什么 ==="
cat /proc/1958/cmdline 2>/dev/null | tr '\0' ' '
echo
echo "=== cloud 服务状态 ==="
for u in mipi-cloud cloud-agent mipi-cloud-agent cloud; do
    s=$(systemctl is-active $u 2>/dev/null)
    [ -n "$s" ] && [ "$s" != "inactive" ] && echo "  $u = $s"
done
echo
echo "=== cloud 日志 (最近 30 行) ==="
for f in /root/rk/deploy/cloud*.log /tmp/cloud*.log /var/log/cloud*.log \
         /root/rk/web/cloud*.log /root/cloud*.log; do
    [ -f "$f" ] && { echo "--- $f ---"; tail -30 "$f"; }
done
echo
echo "=== 最近 5 分钟 cloud 日志(如果有 journal) ==="
journalctl -u mipi-cloud --since '-5min' --no-pager 2>/dev/null | tail -20
