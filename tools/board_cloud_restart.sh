#!/bin/sh
echo "=== 重启 cloud-agent 并抓日志 ==="
systemctl restart cloud-agent
sleep 14
echo "--- journalctl -u cloud-agent ---"
journalctl -u cloud-agent -n 50 --no-pager 2>&1 | tail -40
echo
echo "--- 进程与连接 ---"
P=$(pgrep -f cloud_agent.py | head -1)
echo "  pid=$P"
ss -tnp 2>/dev/null | grep "pid=$P" | head -4
echo
echo "--- 再等 12 秒看是否稳定(没退出/没重启) ---"
sleep 12
echo "  is-active = $(systemctl is-active cloud-agent)"
echo "  NRestarts = $(systemctl show cloud-agent -p NRestarts --value)"
journalctl -u cloud-agent --since '-30s' --no-pager 2>&1 | tail -15
