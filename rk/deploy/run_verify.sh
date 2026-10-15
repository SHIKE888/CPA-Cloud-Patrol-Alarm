#!/bin/sh
# run_verify.sh —— 在开发板上跑链路比特精确性验证
#
# 用法:  sh /root/rk/deploy/run_verify.sh [设备] [帧数]
#        sh /root/rk/deploy/run_verify.sh            # 默认 /dev/video22 抓 3 帧
#
# 会先让出 /dev/video22 (关掉可能还在跑的推流进程), 再抓原始帧比对。
# 注意 pkill 模式用 'mipi_web[s]tream' 的方括号写法 —— 否则 pkill 会匹配到
# 它自己所在的这条 ssh 命令行, 把当前 shell 一起杀掉。

DEV=${1:-/dev/video22}
N=${2:-3}
PY=/opt/miniforge3/envs/mlk-ov/bin/python

echo "== 让出 $DEV =="
pkill -f 'mipi_web[s]tream' 2>/dev/null && echo "  已停止 mipi_webstream" || echo "  没有在跑的推流进程"
pkill -f 'gst-launch'      2>/dev/null
sleep 1

echo "== 当前占用 $DEV 的进程 =="
fuser -v "$DEV" 2>&1 || echo "  (无)"

echo ""
exec $PY /root/rk/deploy/verify_link.py "$DEV" "$N"
