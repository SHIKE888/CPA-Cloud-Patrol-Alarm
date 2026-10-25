#!/bin/bash
# 车端用户态：把 bridge / rosbridge 写进用户 crontab 开机自启（幂等，无需 sudo）
# 用法： bash add_autostart.sh
LINE_BRIDGE='@reboot sleep 25 && $HOME/ros_relay/start_bridge.sh >> $HOME/ros_relay/bridge.log 2>&1'
LINE_ROSBRIDGE='@reboot sleep 30 && $HOME/ros_relay/start_rosbridge.sh 9090 >> $HOME/ros_relay/rosbridge.log 2>&1'

TMP=$(mktemp)
crontab -l 2>/dev/null > "$TMP"

grep -q 'ros_relay/start_bridge.sh' "$TMP" || echo "$LINE_BRIDGE" >> "$TMP"
grep -q 'ros_relay/start_rosbridge.sh' "$TMP" || echo "$LINE_ROSBRIDGE" >> "$TMP"

crontab "$TMP"
rm -f "$TMP"

echo "== 当前 crontab =="
crontab -l | grep -e start_bridge -e start_rosbridge
echo
echo "注意：两个进程都依赖 ROS master(11311) 存在；"
echo "      开机后跑 roslaunch（如 mapping.launch）会自动起 master，它们会自动连上。"
