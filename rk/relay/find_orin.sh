#!/bin/bash
# 从中继自己跑着的 dnsmasq 租约里查出车端 eth1 的真实 IP，再 ssh 上去。
#
# 为什么需要这个：
#   车端 sudo 要密码，没法在车端把 eth1 固定成静态 IP；它的 NetworkManager
#   连接放在 /run/ 下（重启即丢，靠 NM 自动重建）。所以车端 IP 理论上可能不是
#   192.168.100.87。与其赌它不变，不如每次连之前先问一句 dnsmasq：
#   车端 MAC 00:e0:4c:68:00:10 现在拿的是哪个地址。
#
# 用法：
#   /root/ros_relay/find_orin.sh hostname
#   /root/ros_relay/find_orin.sh uptime
#   从 PC 上：ssh afc03 /root/ros_relay/find_orin.sh hostname
set -u

MAC=00:e0:4c:68:00:10
LEASES=/var/lib/misc/dnsmasq.leases
FALLBACK=192.168.100.87

IP=$(awk -v m="$MAC" '$2==m {print $3}' "$LEASES" 2>/dev/null | head -1)

if [ -z "$IP" ]; then
  IP=$FALLBACK
  echo "find_orin: 租约里没找到 $MAC，回退到 $IP" >&2
else
  echo "find_orin: $MAC -> $IP" >&2
fi

exec ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \
         "wheeltec@$IP" "$@"
