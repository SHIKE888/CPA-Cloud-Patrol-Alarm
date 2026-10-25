#!/bin/bash
# 把 crontab 里那串靠 sleep 排序的 @reboot 行，换成统一的 start_all.sh。
#
# 旧做法（本次开机就翻车了）：
#   @reboot sleep 10 && roscore
#   @reboot sleep 25 && start_bridge.sh
#   @reboot sleep 30 && start_rosbridge.sh 9090
#   @reboot sleep 40 && relay_ctl.py
# 问题：roscore 慢一点，后面三条全废；而且没有任何重试。
#
# 新做法：
#   @reboot sleep 8 && start_all.sh        ← 开机拉起（内部有就绪探测）
#   */5 * * * * start_all.sh               ← 看护：谁挂了补谁（幂等，活着就 SKIP）
set -u

BAK="$HOME/ros_relay/crontab.bak2"
OLD=$(crontab -l 2>/dev/null)
printf '%s\n' "$OLD" > "$BAK"
echo "备份 -> $BAK"

# 干掉所有旧的单步 @reboot 行
KEEP=$(printf '%s\n' "$OLD" \
  | grep -v -e 'ros_relay/start_bridge\.sh' \
            -e 'ros_relay/start_rosbridge\.sh' \
            -e 'ros_relay/roscore\.log' \
            -e 'ros_relay/relay_ctl\.py' \
            -e 'ros_relay/start_all\.sh' \
  | grep -v '^[[:space:]]*$')

NEW="$KEEP"
NEW=$(printf '%s\n%s\n' "$NEW" \
  '@reboot sleep 8 && $HOME/ros_relay/start_all.sh >> $HOME/ros_relay/start_all.log 2>&1')
NEW=$(printf '%s\n%s\n' "$NEW" \
  '*/5 * * * * $HOME/ros_relay/start_all.sh >> $HOME/ros_relay/start_all.log 2>&1')

printf '%s\n' "$NEW" | grep -v '^[[:space:]]*$' | crontab -

echo '--- crontab now ---'
crontab -l
