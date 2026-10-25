#!/bin/sh
# 车端 ROS_IP 自动选择（登录 shell 里 source 它即可，无需 root）
# 优先级：USB 网卡(中继链路 enx*/usbeth0) > eth0 > wlan0
for _d in enx usbeth0 eth0 wlan0; do
    _ip=$(ip -4 -o addr show dev "$_d" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "${_ip:-}" ]; then
        export ROS_IP="$_ip"
        export ROS_HOSTNAME="$_ip"
        break
    fi
done
export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"
unset _d _ip
