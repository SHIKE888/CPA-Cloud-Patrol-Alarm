#!/bin/bash
# 给车端补上 roscore 和 relay_ctl 的开机自启。
#
# 现状问题：crontab 里只有 foxglove_bridge(sleep 25) 和 rosbridge(sleep 30)，
# 但 roscore 根本没人拉 —— rosbridge 起来后连不上 master，会一直重连失败。
# relay_ctl 也缺，网页上的建图/保存/导航服务就全都没有。
#
# 启动顺序（靠 sleep 拉开）：
#   10s roscore -> 25s foxglove_bridge -> 30s rosbridge -> 40s relay_ctl
#
# 幂等：已经在 crontab 里的行不会重复添加。
set -u

BAK="$HOME/ros_relay/crontab.bak"
CB=$(crontab -l 2>/dev/null)

printf '%s\n' "$CB" > "$BAK"
echo "备份 crontab -> $BAK"

add() {
  line="$1"
  if printf '%s\n' "$CB" | grep -qxF "$line"; then
    echo "EXISTS  $line"
  else
    CB=$(printf '%s\n' "$CB"; printf '%s\n' "$line")
    echo "ADDED   $line"
  fi
}

add '@reboot sleep 10 && . /opt/ros/noetic/setup.bash && roscore >> $HOME/ros_relay/roscore.log 2>&1'
add '@reboot sleep 40 && . /opt/ros/noetic/setup.bash && python3 $HOME/ros_relay/relay_ctl.py >> $HOME/ros_relay/relay_ctl.log 2>&1'

printf '%s\n' "$CB" | crontab -

echo '--- crontab now ---'
crontab -l
