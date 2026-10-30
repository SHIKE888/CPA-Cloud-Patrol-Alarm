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
#
# ★ 2026-10-31 启动加速（用户反馈「bridge 起得太慢」）
#   实测（journalctl -b -o short-monotonic，开机后秒数）：
#     [ 12.8] cron 跑 @reboot -> sleep 8
#     [ 20.8] start_all 开始
#     [ 23.8] roscore 就绪
#     [ 24.8] foxglove 就绪   <- 串行 wait_port
#     [ 26.8] rosbridge 就绪  <- 串行 wait_port
#     [ 31.8] relay_ctl       <- 再单独 sleep 5
#   改法：
#     1) crontab 的 sleep 8 -> 2（start_all 自带 wait_port，不需要死等）；
#     2) foxglove / rosbridge / relay_ctl 互不依赖，**并行起**，
#        总耗时从 1+2+5=8s 变成 max(1,2,5)=5s；
#     3) 每行日志带「脚本内已用秒数」，下次看日志能直接定位慢在哪一段。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROS_SETUP=/opt/ros/noetic/setup.bash
T0=$(date +%s)

say() { printf '[%s +%ss] %s\n' "$(date +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }

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

# ── 0. eth1（连板子的 USB 网卡）──────────────────────────────
#   ⚠ 不要在启动链路里"重新 probe"来抢时间：实测 unbind 会被那个已经卡在
#     request_firmware 里的 probe 挡住，等满 60 秒才返回，反而把后面的 roscore
#     拖到开机 66 秒。真因是 /boot/initrd 里没有 rtl8153b-2.fw（只有 a-4 版），
#     唯一的修法是把固件放进 /boot/initrd，那是引导镜像改动，另行处理。
#     这里只做一次**非阻塞**的自检日志，不影响启动时序。
if ! ip -4 addr show eth1 2>/dev/null | grep -q "inet "; then
  say "注意 eth1 暂无 IP（r8152 固件回退，约 71s 后才就绪）"
fi

# ── 1. roscore（后面三个都要等 master，必须串行）────────────
if port_up 11311; then
  say "SKIP roscore  已在跑"
else
  say "START roscore"
  nohup bash -c ". $ROS_SETUP; exec roscore" >> "$HERE/roscore.log" 2>&1 &
fi
wait_port 11311 60 roscore || exit 1

# ── 2/3/4. foxglove(8765) / rosbridge(9090) / relay_ctl 并行起 ──
#   三者互不依赖，只要 master 在就行。原来一行一行 wait_port 白等 3 秒，
#   再单独 sleep 5 等 relay_ctl，属实没必要。
RC_PID=""

if port_up 8765; then
  say "SKIP foxglove_bridge  已在跑"
else
  # 有游离进程但没监听端口（比如起来时 master 不在），先清掉再起
  if proc_up 'foxglove_bridge'; then
    say "清理连不上 master 的 foxglove_bridge"
    pkill -f 'foxglove_bridge' 2>/dev/null
    sleep 1
  fi
  say "START foxglove_bridge"
  nohup "$HERE/start_bridge.sh" >> "$HERE/bridge.log" 2>&1 &
fi

if port_up 9090; then
  say "SKIP rosbridge  已在跑"
else
  say "START rosbridge"
  nohup "$HERE/start_rosbridge.sh" 9090 >> "$HERE/rosbridge.log" 2>&1 &
fi

if proc_up 'relay_ctl[.]py'; then
  say "SKIP relay_ctl  已在跑"
else
  say "START relay_ctl"
  nohup bash -c ". $ROS_SETUP; exec python3 $HERE/relay_ctl.py" >> "$HERE/relay_ctl.log" 2>&1 &
  RC_PID=$!          # exec 之后 PID 不变，直接 kill -0 判存活
fi

wait_port 8765 60 foxglove_bridge
wait_port 9090 60 rosbridge

# relay_ctl 起来大约要 4~5 秒（连 master + 建 TF/map 订阅），按 PID 等存活。
# 原来这里是死等 sleep 5，现在它和上面两个 wait_port 并行进行，只补足差额。
if [ -n "$RC_PID" ]; then
  i=0
  while [ "$i" -lt 12 ]; do
    kill -0 "$RC_PID" 2>/dev/null || break
    [ "$i" -ge 5 ] && break
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$RC_PID" 2>/dev/null; then
    say "OK   relay_ctl"
  else
    say "FAIL relay_ctl  见 $HERE/relay_ctl.log"
  fi
elif proc_up 'relay_ctl[.]py'; then
  say "OK   relay_ctl（已在跑）"
fi

say "==== 全栈就绪 ===="
