#!/bin/bash
# 车端用户态启动 rosbridge_websocket（不需要 root）
# 依赖（均 dpkg -x / wheel 解包到用户目录）：
#   ~/ros_ext/opt/ros/noetic/{share,lib/python3/dist-packages}/rosbridge_*
#   ~/ros_ext/py/tornado            （wheel 解压，系统 python3 没有 tornado）
# 用法： ./start_rosbridge.sh [端口，默认 9090]
EXT=$HOME/ros_ext/opt/ros/noetic
LOG=$HOME/ros_relay/rosbridge.log
mkdir -p "$HOME/ros_relay"

. /opt/ros/noetic/setup.bash 2>/dev/null || { echo "没有 /opt/ros/noetic" >&2; exit 1; }

export ROS_PACKAGE_PATH="$EXT/share${ROS_PACKAGE_PATH:+:$ROS_PACKAGE_PATH}"
export PYTHONPATH="$EXT/lib/python3/dist-packages:$HOME/ros_ext/py${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$EXT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$EXT${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PATH="$EXT/bin:$PATH"

for d in enx usbeth0 eth0 wlan0; do
    ip=$(ip -4 -o addr show dev "$d" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "${ip:-}" ]; then export ROS_IP="$ip"; break; fi
done
# 开机很早（systemd ~7s）时网卡可能还没拿到 IP —— 回落到回环，
# 否则 ROS_IP 留空会走主机名，行为不确定。车端所有节点都在本机。
[ -n "${ROS_IP:-}" ] || export ROS_IP=127.0.0.1
export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"

PORT=${1:-9090}
echo "[$(date '+%F %T')] start_rosbridge port=$PORT ROS_IP=${ROS_IP:-unset}" >>"$LOG"
exec "$EXT/lib/rosbridge_server/rosbridge_websocket" _port:=$PORT
