#!/bin/sh
# /etc/profile.d/ros_relay.sh —— 车端 ROS 多机环境（中继链路优先）
# 规则：中继链路(usbeth0 / 192.168.100.1) 在就用它；否则退回 eth0；再否则 wlan0
# ROS_MASTER_URI 固定 127.0.0.1（master 跑在车端本机，中继只做 WS 反代，不跑 ROS）

_ros_relay_pick_ip() {
    for dev in usbeth0 enx* eth0 wlan0; do
        [ "$dev" = "enx*" ] && continue
        ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 && return 0
    done
    # 兜底：任何 enx* 接口（USB 网卡改名失败时）
    for dev in $(ls /sys/class/net | grep '^enx'); do
        ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 && return 0
    done
    return 1
}

ROS_IP=$(_ros_relay_pick_ip)
[ -n "$ROS_IP" ] && export ROS_IP
export ROS_MASTER_URI=http://127.0.0.1:11311
export ROS_HOSTNAME=$ROS_IP
