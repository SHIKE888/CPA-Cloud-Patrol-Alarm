#!/bin/sh
# 车端(Jetson Orin Nano, Ubuntu 20.04 + ROS noetic) 中继前置预备
# 用法： sudo sh apply_prep.sh            （在 ~/ros_relay_prep 目录里执行）
#        sudo sh apply_prep.sh --with-ros  （额外尝试 apt 安装 foxglove_bridge / rosbridge）
# 幂等：重复执行安全；被覆盖的配置留 .bak_rosrelay
set -e
SRC=$(cd "$(dirname "$0")" && pwd)
WITH_ROS=0
[ "$1" = "--with-ros" ] && WITH_ROS=1

echo "== 1) udev：RTL8153 -> usbeth0 =="
cp "$SRC/70-ros-relay-net.rules" /etc/udev/rules.d/70-ros-relay-net.rules
udevadm control --reload-rules
udevadm trigger --subsystem-match=net || true
echo "   规则已安装：$(ls -l /etc/udev/rules.d/70-ros-relay-net.rules | awk '{print $NF}')"

echo "== 2) NetworkManager 静态链路 192.168.100.1/24 =="
if nmcli -t -f NAME con show | grep -qx ros-relay-car; then
    echo "   已存在，跳过"
else
    nmcli con add type ethernet ifname usbeth0 con-name ros-relay-car \
        ipv4.method manual ipv4.addresses 192.168.100.1/24 \
        ipv4.never-default yes ipv6.method ignore autoconnect yes
fi
nmcli -g ipv4.method,ipv4.addresses,ipv4.never-default con show ros-relay-car

echo "== 3) chrony 客户端（server = 中继） =="
if ! dpkg -s chrony >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chrony || echo "   注意：chrony 安装失败（无外网？）"
fi
if [ -f /etc/chrony/chrony.conf ]; then
    [ -f /etc/chrony/chrony.conf.bak_rosrelay ] || cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak_rosrelay
    cp "$SRC/chrony-client.conf" /etc/chrony/chrony.conf
    systemctl enable chrony >/dev/null 2>&1 || true
    systemctl restart chrony || true
fi

echo "== 4) /etc/hosts 互解析 =="
grep -q 'ros-relay' /etc/hosts || echo '192.168.100.2 ros-relay' >> /etc/hosts
grep -q 'ros-car'   /etc/hosts || echo '192.168.100.1 ros-car'   >> /etc/hosts
tail -3 /etc/hosts

echo "== 5) ROS 多机环境变量 =="
cp "$SRC/ros_relay_env.sh" /etc/profile.d/ros_relay.sh
chmod 644 /etc/profile.d/ros_relay.sh
echo "   已装 /etc/profile.d/ros_relay.sh（新登录 shell 生效）"

echo "== 6) web_goal_bridge.py =="
install -m 755 "$SRC/web_goal_bridge.py" /usr/local/bin/web_goal_bridge.py
echo "   /usr/local/bin/web_goal_bridge.py"

if [ "$WITH_ROS" = "1" ]; then
    echo "== 7) apt 安装 foxglove_bridge / rosbridge =="
    # 车端无外网时，用 PC 侧代理：sudo env APT_PROXY=http://127.0.0.1:8811 sh apply_prep.sh --with-ros
    APTOPTS=""
    [ -n "$APT_PROXY" ] && APTOPTS="-o Acquire::http::Proxy=$APT_PROXY -o Acquire::https::Proxy=$APT_PROXY"
    echo "   proxy=${APT_PROXY:-无}"
    apt-get $APTOPTS update -qq || echo "   apt update 失败（无外网？）"
    DEBIAN_FRONTEND=noninteractive apt-get $APTOPTS install -y -qq \
        ros-noetic-foxglove-bridge ros-noetic-rosbridge-server \
        || echo "   安装失败：需要外网或离线 deb，见方案文档「车端离线安装」"
fi

echo "== 8) 验收 =="
echo "--- 网卡 ---"
ls /sys/class/net | tr '\n' ' '; echo
ip -br addr | grep -E 'usbeth0|enx|eth0' || true
echo "--- nm ---"
nmcli -g ipv4.addresses con show ros-relay-car || true
echo "--- chrony ---"
chronyc sources 2>/dev/null | head -5 || echo "   chrony 未运行"
echo "--- ROS ---"
. /opt/ros/noetic/setup.bash 2>/dev/null && echo "   rosversion=$(rosversion -d)" || echo "   未找到 /opt/ros/noetic"
rospack find foxglove_bridge 2>/dev/null || echo "   foxglove_bridge: 未安装"
rospack find rosbridge_server 2>/dev/null || echo "   rosbridge_server: 未安装"
echo
echo "DONE"
