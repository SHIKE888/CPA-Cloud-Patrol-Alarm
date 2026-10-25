#!/bin/sh
# 车端用户态安装（不需要 root）：把中继相关的用户级脚本装好
# 用法： sh install_user_side.sh
set -e
SRC=$(cd "$(dirname "$0")" && pwd)
DEST=$HOME/ros_relay
mkdir -p "$DEST"

echo "== 1) 安装脚本到 ~/ros_relay =="
cp "$SRC/start_bridge.sh" "$DEST/start_bridge.sh"
chmod +x "$DEST/start_bridge.sh"
cp "$SRC/web_goal_bridge.py" "$DEST/web_goal_bridge.py"
chmod +x "$DEST/web_goal_bridge.py"
cp "$SRC/ros_ip_env.sh" "$DEST/ros_ip_env.sh"
ls -l "$DEST"

echo "== 2) ~/.bashrc 里挂 ROS_IP 自动探测（幂等） =="
if ! grep -q 'ros_relay/ros_ip_env.sh' "$HOME/.bashrc"; then
    printf '\n# ROS 中继链路 ROS_IP 自动选择\n[ -f "$HOME/ros_relay/ros_ip_env.sh" ] && . "$HOME/ros_relay/ros_ip_env.sh"\n' >> "$HOME/.bashrc"
    echo "   已追加到 ~/.bashrc"
else
    echo "   已存在，跳过"
fi

echo "== 3) 开机自启 foxglove_bridge（用户 crontab，免 root） =="
if crontab -l 2>/dev/null | grep -q 'ros_relay/start_bridge.sh'; then
    echo "   已存在，跳过"
else
    ( crontab -l 2>/dev/null; \
      echo '@reboot sleep 25 && $HOME/ros_relay/start_bridge.sh >> $HOME/ros_relay/bridge.log 2>&1' ) | crontab -
    echo "   已写入 crontab"
fi
crontab -l | tail -3

echo "== 4) 自检 =="
echo "--- 解包目录 ---"
ls -l "$HOME/ros_ext/opt/ros/noetic/lib/foxglove_bridge/foxglove_bridge" 2>/dev/null || echo "   缺少 ros_ext（需先 dpkg -x）"
echo "--- 当前网卡 ---"
ip -4 -o addr show 2>/dev/null | awk '{print "   " $2, $4}' | grep -v ' lo '
echo
echo "DONE（全部为用户态操作，未使用 sudo）"
