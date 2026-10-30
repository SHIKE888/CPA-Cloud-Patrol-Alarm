#!/bin/sh
# 车端上电校时（2026-10-30）  ——  部署到 ~/ros_relay/time_sync_retry.sh
#
# 背景（实测）：
#   车端 cron 的 @reboot 任务能正常跑，但**所有 */N 定时任务从不触发**：
#     - /etc/cron.d/rk-time 里 `*/5 ... rk-time-sync`      -> /var/log/rk-time.log 自开机起再没被写过
#     - 用户 crontab 里的 `*/5 ... start_all.sh`           -> start_all.log 自开机起再没被写过
#     - journalctl -u cron 开机后只有 3 条 CMD，全是 @reboot / hourly run-parts
#   于是「开机 30 秒后同步一次，之后每 5 分钟重试」这条退路根本不存在：
#   只要开机 30 秒那一次板子还没就绪（Jetson 起得比 RK3576 快），
#   车端时间就会一直停在 RTC 的默认值（实测差 856 天，2024-06-26）。
#
# 对策：
#   把重试循环搬进 @reboot 任务本身，最多 20 分钟，成功即退出。
#   循环靠 sleep 推进（单调时长），不依赖墙上时钟——时钟本身就是错的。
#
# 安装（不需要 root，sudoers 只放开了 rk-time-sync 这一个文件）：
#   cp time_sync_retry.sh ~/ros_relay/ && chmod +x ~/ros_relay/time_sync_retry.sh
#   (crontab -l 2>/dev/null; echo '@reboot $HOME/ros_relay/time_sync_retry.sh') | crontab -
#
# 日志：/tmp/rk-time-retry.log

LOG=/tmp/rk-time-retry.log

for i in $(seq 1 120); do
    if sudo -n /usr/local/bin/rk-time-sync >> "$LOG" 2>&1; then
        echo "$(date '+%F %T') 第 $i 次尝试成功" >> "$LOG"
        exit 0
    fi
    sleep 10
done

echo "$(date '+%F %T') 20 分钟内一直取不到板端时间" >> "$LOG"
exit 1
