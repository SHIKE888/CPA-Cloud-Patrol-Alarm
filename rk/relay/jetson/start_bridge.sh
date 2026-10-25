#!/bin/bash
# 车端用户态启动 foxglove_bridge（不需要 root）
# 依赖：~/ros_ext/opt/ros/noetic/lib/foxglove_bridge/foxglove_bridge
#       （由 ros-noetic-foxglove-bridge_0.8.4_arm64.deb 用 dpkg -x 解包得到）
# 用法： ./start_bridge.sh [额外参数]      默认 _port:=8765
#        nohup ./start_bridge.sh >/dev/null 2>&1 &

EXT=$HOME/ros_ext/opt/ros/noetic
LOG=$HOME/ros_relay/bridge.log
mkdir -p "$HOME/ros_relay"

# 1) 基础 ROS 环境
. /opt/ros/noetic/setup.bash 2>/dev/null || { echo "没有 /opt/ros/noetic" >&2; exit 1; }
# 2) 车端工作空间（可选。实测 source wheeltec_* 的 devel/setup.bash 很慢，
#    而 bridge 只需要 ROS 基础环境，默认不加载；需要时 export ROSOURCES_WS=1）
if [ "${ROSOURCES_WS:-0}" = "1" ]; then
    for w in "$HOME/wheeltec_lidar/devel" "$HOME/wheeltec_robot/devel"; do
        [ -f "$w/setup.bash" ] && . "$w/setup.bash"
    done
fi
# 3) 把 dpkg -x 解出来的包挂进 ROS 搜索路径
#    CMAKE_PREFIX_PATH 必须设：foxglove_bridge 是 nodelet 容器，pluginlib 靠它定位插件库
export ROS_PACKAGE_PATH="$EXT/share${ROS_PACKAGE_PATH:+:$ROS_PACKAGE_PATH}"
export LD_LIBRARY_PATH="$EXT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$EXT${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PATH="$EXT/bin:$PATH"

# 4) ROS_IP 自动选择：USB 网卡(中继链路) > eth0 > wlan0
for d in enx usbeth0 eth0 wlan0; do
    ip=$(ip -4 -o addr show dev "$d" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "${ip:-}" ]; then
        export ROS_IP="$ip"
        break
    fi
done
export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"

echo "[$(date '+%F %T')] start_bridge ROS_IP=${ROS_IP:-unset} MASTER=$ROS_MASTER_URI" >>"$LOG"

BIN=$EXT/lib/foxglove_bridge/foxglove_bridge
[ -x "$BIN" ] || { echo "缺少 $BIN" >&2; exit 2; }

# 5) 默认端口 8765；允许调用方传参覆盖
if [ $# -gt 0 ]; then
    exec "$BIN" "$@"
else
    exec "$BIN" _port:=8765
fi
