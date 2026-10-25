#!/bin/bash
# 打印车端各 ROS 进程实际生效的 ROS_* 地址变量。
#
# 为什么要单独查：.bashrc 顶部有 `case $- in *i*) ;; *) return;; esac`，
# 非交互 shell（crontab、`ssh host 'cmd'`）根本不会执行到后面的 export，
# 所以「.bashrc 里写了 ROS_HOSTNAME=192.168.0.100」并不代表正在跑的进程
# 真的用了它。必须看 /proc/<pid>/environ 才算数。
for name in rosbridge_websocket relay_ctl slam_gmapping foxglove; do
    P=$(pgrep -f "$name" | head -1)
    if [ -z "$P" ]; then
        printf '%-22s (未运行)\n' "$name"
        continue
    fi
    printf '=== %s  PID=%s ===\n' "$name" "$P"
    tr '\0' '\n' < "/proc/$P/environ" 2>/dev/null \
        | grep -a -E '^(ROS_MASTER_URI|ROS_HOSTNAME|ROS_IP)=' \
        || echo '    (没有 ROS_* 环境变量 -> 用默认 localhost / 本机 hostname)'
done
echo '--- 本机各网卡 ---'
ip -4 -br addr show | grep -v -e LOOPBACK
