#!/bin/bash
# 车端 ROS 中继全栈启动器：幂等 + 就绪探测。
#
# 为什么不用 crontab 里一串 `sleep 10/25/30/40 && xxx`：
#   1. sleep 是死的，roscore 慢一点后面全失败（本机就踩过：开机 27 分钟时
#      rosmaster / rosbridge 一个都没起来，foxglove_bridge 在空转）；
#   2. 没有幂等，重复执行会起出两个同名进程；
#   3. 不知道启动成功还是失败，只能事后看日志。
#
# 本脚本可以反复执行（开机、手动修复、看护定时器都调它）：
#   - 端口已经在监听就跳过
#   - 每一步都等端口就绪，超时明确报错
#
# 不启动建图/导航 launch —— 那是按需的，由网页上的「开始建图」按钮触发。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROS_SETUP=/opt/ros/noetic/setup.bash

say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

port_up() { ss -lnt 2>/dev/null | grep -q ":$1 "; }

# 用 [r]elay_ctl 这种写法避免 pgrep 匹配到本脚本自身的命令行
proc_up() { pgrep -f "$1" >/dev/null 2>&1; }

wait_port() {  # wait_port PORT TIMEOUT NAME
  local p="$1" t="${2:-60}" n="${3:-port}" i=0
  while [ "$i" -lt "$t" ]; do
    if port_up "$p"; then
      say "OK   $n  监听 :$p（等待 ${i}s）"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  say "FAIL $n  超时 ${t}s 仍未监听 :$p"
  return 1
}

cd "$HERE" || exit 1

# ── 1. roscore ────────────────────────────────────────────────
if port_up 11311; then
  say "SKIP roscore  已在跑"
else
  say "START roscore"
  nohup bash -c ". $ROS_SETUP; exec roscore" >> "$HERE/roscore.log" 2>&1 &
fi
wait_port 11311 60 roscore || exit 1

# ── 2. foxglove_bridge (8765) ─────────────────────────────────
if port_up 8765; then
  say "SKIP foxglove_bridge  已在跑"
else
  # 有游离进程但没监听端口（比如起来时 master 不在），先清掉再起
  if proc_up 'foxglove_bridge'; then
    say "清理连不上 master 的 foxglove_bridge"
    pkill -f 'foxglove_bridge' 2>/dev/null
    sleep 2
  fi
  say "START foxglove_bridge"
  nohup "$HERE/start_bridge.sh" >> "$HERE/bridge.log" 2>&1 &
fi
wait_port 8765 60 foxglove_bridge

# ── 3. rosbridge_websocket (9090) ─────────────────────────────
if port_up 9090; then
  say "SKIP rosbridge  已在跑"
else
  say "START rosbridge"
  nohup "$HERE/start_rosbridge.sh" 9090 >> "$HERE/rosbridge.log" 2>&1 &
fi
wait_port 9090 60 rosbridge

# ── 4. relay_ctl（提供 /relay/* 服务与 /relay/map）─────────────
if proc_up 'relay_ctl[.]py'; then
  say "SKIP relay_ctl  已在跑"
else
  say "START relay_ctl"
  nohup bash -c ". $ROS_SETUP; exec python3 $HERE/relay_ctl.py" >> "$HERE/relay_ctl.log" 2>&1 &
  sleep 5
  if proc_up 'relay_ctl[.]py'; then
    say "OK   relay_ctl"
  else
    say "FAIL relay_ctl  见 $HERE/relay_ctl.log"
  fi
fi

say "==== 全栈就绪 ===="
