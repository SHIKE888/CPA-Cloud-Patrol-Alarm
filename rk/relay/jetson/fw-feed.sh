#!/bin/sh
# fw-feed.sh —— 抢在 60 秒超时前，替内核把 r8152 的固件喂进去（2026-10-31）
#
# 背景（journalctl -b -o short-monotonic 实测）：
#   [11.02] r8152 Direct firmware load for rtl_nic/rtl8153b-2.fw failed (-2)
#   [11.04] Falling back to sysfs fallback
#   [13.51] systemd-udevd 才启动          <- 晚于请求，且不会回头捡挂起的请求
#   [71.11] unable to load firmware patch (-110，60 秒超时)
#   [71.20] eth1 出现                     <- 板子连车的唯一通路
#
# 那 60 秒就是在等用户态按老式接口把数据写进 sysfs。这里自己写：
#   loading <- 1 ; data <- <固件> ; loading <- 0
# 内核收到数据后 probe 立即继续，eth1 约 13~14 秒就能起来。
# 不动 /boot/initrd，不动内核参数；最坏情况只是本脚本什么也没做。
LOG=/var/log/fw-feed.log
FW=/lib/firmware/rtl_nic/rtl8153b-2.fw
say() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

[ -f "$FW" ] || { say "找不到 $FW，退出"; exit 0; }
ip -4 addr show eth1 2>/dev/null | grep -q "inet " && { say "eth1 已有 IP，无需处理"; exit 0; }
say "开始监控 /sys/class/firmware（最多 70 秒）"

i=0
fed=0
while [ "$i" -lt 70 ]; do
    names=$(ls /sys/class/firmware/ 2>/dev/null | grep -v '^timeout$')
    if [ -n "$names" ] && [ "$fed" = "0" ]; then
        say "发现挂起请求: $(echo $names)"
        for n in $names; do
            d="/sys/class/firmware/$n"
            case "$n" in
                *rtl8153*|*2-3*)
                    say "喂 $n"
                    if echo 1 > "$d/loading" 2>>"$LOG" \
                       && cat "$FW" > "$d/data" 2>>"$LOG" \
                       && echo 0 > "$d/loading" 2>>"$LOG"; then
                        say "喂完 $n"
                        fed=1
                    else
                        say "喂失败 $n"
                    fi
                    ;;
                *)
                    say "跳过不认识的请求 $n（不乱喂，免得把别人的固件写坏）"
                    ;;
            esac
        done
    fi
    if ip -4 addr show eth1 2>/dev/null | grep -q "inet "; then
        say "eth1 已就绪（第 ${i}s 轮）"
        exit 0
    fi
    sleep 1
    i=$((i+1))
done
say "70 秒结束，eth1 仍无 IP"
