#!/bin/bash
#=============================================================================
#  start.sh —— 开发板一键启动: MIPI 网页推流 + AI 人体/姿态标注
#
#  用法:
#     start.sh              # 默认 1080p60 + AI 标注 + 云端推送（已实测稳定）
#     start.sh 1080         # 同上
#     start.sh 4k           # 切到 4K25 再启动（注意 4K 画质仍在修）
#     start.sh stop         # 停止推流 + 云端推送
#     start.sh status       # 看当前状态
#     start.sh cloud        # 只拉云端推送代理（开机脚本 boot_start.sh 用这个）
#     start.sh cloud-stop   # 只停云端推送代理
#
#  云端推送代理（/root/rk/cloud/cloud_agent.py）与推流一起自启：
#     * 默认 CLOUD=1；想只跑推流就 `CLOUD=0 start.sh`
#     * 有 systemd 单元 cloud-agent.service 时交给 systemd（崩溃自动重启）
#     * 没有单元就 nohup 后台跑，日志 /tmp/cloud_agent.log
#
#  可直接调的环境变量:
#     DEV=/dev/video22     采集设备
#     PORT=9012            HTTP 端口
#     CLOUD=1              1=同时拉起云端推送代理, 0=不拉起
#     SERVER=http://<SERVER_DOMAIN>   云端地址（nohup 方式时用）
#     AI_FPS=30            AI 帧率上限
#     AI_INTERVAL=2        检测间隔（每 N 帧跑一次一级检测）
#     AI_SRC=ai            启动即显示 AI 标注画面（=raw 则显示原图）
#     AI_ZONE='...'        越界警戒区
#
#  依据 docs/ARCHIVE_2026-10-16.md:
#     * AI 走【集成】模式（AI=1 挂在 9012 里），不要起 9013 独立版
#       —— 集成模式省掉一次 JPEG 解码 + 一次编码 + 一路回环，CPU 416% → 270%
#     * 9013 独立版只在"需要从别处取流"时才用
#=============================================================================
set -u

DEV=${DEV:-/dev/video22}
PORT=${PORT:-9012}
WEB=${WEB:-/root/rk/web}
FPGA=${FPGA:-/root/rk/deploy/fpga_cfg.py}
LOG=${LOG:-/tmp/mipi_start.log}
AI_FPS=${AI_FPS:-30}
AI_INTERVAL=${AI_INTERVAL:-2}
AI_SRC=${AI_SRC:-ai}

# ---- 云端推送代理（cloud_agent.py）----
CLOUD=${CLOUD:-1}
CLOUD_DIR=${CLOUD_DIR:-/root/rk/cloud}
AGENT=${AGENT:-$CLOUD_DIR/cloud_agent.py}
CLOUD_LOG=${CLOUD_LOG:-/tmp/cloud_agent.log}
CLOUD_SVC=${CLOUD_SVC:-cloud-agent}
SERVER=${SERVER:-}
NODE=${NODE:-$(hostname 2>/dev/null || echo afc03)}
NODE_NAME=${NODE_NAME:-AFC03 IMX415}

MODE=${1:-1080}
IP=$(hostname -I 2>/dev/null | awk '{print $1}')

c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m%s\033[0m\n' "$*"; }

# 端口是否在监听 (优先 ss, 没装就用 netstat)
listening() {
    local p=$1
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -q ":$p " && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -q ":$p " && return 0
    fi
    return 1
}

# 列出所有监听端口
list_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | grep -E '901[0-9]'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntp 2>/dev/null | grep -E '901[0-9]'
    fi
}

#--------------------------------------------------------------- 云端推送
# 注意: 不能用 pgrep -f 'cloud_agent.py' 裸匹配 ——
#   本脚本自己/ssh 命令行里只要出现这个字符串（如 `ps | grep cloud_agent.py`）
#   就会被误认为“已在运行”，开机时代理就不拉了。
# 做法: 有 systemd 单元就以 MainPID 为准；pgrep 也加行首锚点只认 python 进程。
has_unit()  { systemctl list-unit-files 2>/dev/null | grep -q "^$1\.service"; }
agent_pid() {
    local pid=""
    if has_unit "$CLOUD_SVC"; then
        pid=$(systemctl show -p MainPID --value "$CLOUD_SVC" 2>/dev/null)
        [ "${pid:-0}" = "0" ] && pid=""
    fi
    if [ -z "$pid" ]; then
        pid=$(pgrep -f '^/usr/bin/python[0-9.]* .*cloud_agent\.py' 2>/dev/null | head -1)
    fi
    [ "${pid:-0}" = "0" ] && pid=""
    echo "$pid"
}
cloud_active() { has_unit "$CLOUD_SVC" && systemctl is-active --quiet "$CLOUD_SVC" 2>/dev/null; }

cloud_start() {
    if [ "$CLOUD" != "1" ]; then
        echo "  云端推送  : 已跳过 (CLOUD=0)"
        return 0
    fi
    local pid
    pid=$(agent_pid)
    if [ -n "$pid" ]; then
        echo "  云端推送  : 已在运行 (pid $pid)"
        return 0
    fi
    if [ ! -f "$AGENT" ]; then
        c_warn "  云端推送  : 未安装 $AGENT, 跳过"
        return 0
    fi
    # 有 systemd 单元就交给 systemd：崩溃自拉、日志进 journal
    if has_unit "$CLOUD_SVC"; then
        systemctl start --no-block "$CLOUD_SVC" >/dev/null 2>&1
        local i
        for i in 1 2 3 4 5 6 7 8; do
            sleep 1
            cloud_active && break
        done
        pid=$(agent_pid)
        if cloud_active && [ -n "$pid" ]; then
            c_ok "  云端推送  : 已启动 (systemd $CLOUD_SVC, pid $pid)"
            return 0
        fi
        c_warn "  $CLOUD_SVC 没起来, 改用 nohup"
    fi
    nohup /usr/bin/python3 -u "$AGENT" \
        --server "$SERVER" --token-file "$CLOUD_DIR/token" \
        --local "http://127.0.0.1:${PORT}" --node "$NODE" --name "$NODE_NAME" \
        --interval "${CLOUD_INTERVAL:-5}" >"$CLOUD_LOG" 2>&1 &
    sleep 2
    pid=$(agent_pid)
    if [ -n "$pid" ]; then
        c_ok "  云端推送  : 已启动 (nohup, pid $pid, 日志 $CLOUD_LOG)"
    else
        c_err "  云端推送  : 启动失败, 日志尾部:"
        tail -n 10 "$CLOUD_LOG" 2>/dev/null | sed 's/^/     /'
    fi
    return 0
}

cloud_stop() {
    local hit=0
    if cloud_active; then
        systemctl stop "$CLOUD_SVC" >/dev/null 2>&1 && { echo "  已停云端推送 (systemd $CLOUD_SVC)"; hit=1; }
    fi
    # 手工 nohup 起的残留（只认 python 进程，不误杀 shell）
    if pkill -f '^/usr/bin/python[0-9.]* .*cloud_agent\.py' 2>/dev/null; then
        echo "  已停云端推送 (nohup 残留)"
        hit=1
    fi
    [ "$hit" = "1" ] || echo "  云端推送  : 未在运行"
    return 0
}

cloud_status() {
    local pid
    pid=$(agent_pid)
    if [ -n "$pid" ]; then
        c_ok "  云端推送  : 运行中 (pid $pid)"
    else
        c_warn "  云端推送  : 未运行"
    fi
    # 云连通性：断了先看 `ip route`（历史上是 end0 静态网关把 WiFi 默认路由压掉）
    if command -v curl >/dev/null 2>&1; then
        if [ -n "$(curl -s -m 5 "$SERVER/api/ping" 2>/dev/null)" ]; then
            c_ok "  云端连通  : $SERVER OK"
        else
            c_err "  云端连通  : $SERVER 不通 —— 查 DNS / 默认路由 (ip route; getent hosts) "
        fi
    fi
    if has_unit "$CLOUD_SVC"; then
        echo "  服务单元  : $CLOUD_SVC  enabled=$(systemctl is-enabled "$CLOUD_SVC" 2>/dev/null) active=$(systemctl is-active "$CLOUD_SVC" 2>/dev/null)"
    else
        echo "  服务单元  : 无（nohup 方式，日志 $CLOUD_LOG）"
        [ -f "$CLOUD_LOG" ] && tail -n 1 "$CLOUD_LOG" 2>/dev/null | sed 's/^/      日志: /'
    fi
    return 0
}

#--------------------------------------------------------------- 停止
stop_all() {
    local n
    # 注意: 不能用 `pgrep -fc xxx || echo 0` —— pgrep 在 0 匹配时既打印 "0" 又返回 1,
    #       会变成两行 "0\n0", 后面 [: -gt ] 就报"需要整数表达式"。
    n=$(pgrep -f 'mipi_webstream\.py' 2>/dev/null | wc -l)
    n=${n:-0}
    if [ "$n" -gt 0 ]; then
        pkill -f 'mipi_webstream\.py' && echo "  已停 web($n 个进程)"
    else
        echo "  web 未在运行"
    fi
    # 顺带清掉可能残留的 9013 独立版
    if pkill -f 'ai_webstream\.py' 2>/dev/null; then
        echo "  已停 9013 独立版 AI"
    fi
    sleep 2
    n=$(pgrep -f 'mipi_webstream\.py' 2>/dev/null | wc -l)
    n=${n:-0}
    if [ "$n" -gt 0 ]; then
        c_warn "  仍有 $n 个残留, 强制 kill"
        pkill -9 -f 'mipi_webstream\.py' 2>/dev/null
        sleep 1
    fi
    # 推流停了，云端推送也没意义（会一直报 link_down）
    cloud_stop
    return 0
}

#--------------------------------------------------------------- 状态
status() {
    echo "=============================================================="
    echo " MIPI 推流 + 云端推送 状态"
    echo "--------------------------------------------------------------"
    if pgrep -f 'mipi_webstream\.py' >/dev/null 2>&1; then
        c_ok "  web         : 运行中"
    else
        c_warn "  web         : 未运行"
    fi
    if pgrep -f 'ai_webstream\.py' >/dev/null 2>&1; then
        c_warn "  AI(9013独立): 运行中 —— 一般不需要, 建议 start.sh stop 再重起"
    fi
    cloud_status
    local l
    l=$(list_ports)
    [ -n "$l" ] && { echo "  监听端口    :"; echo "$l" | sed 's/^/      /'; }
    if [ -x "$FPGA" ] || [ -f "$FPGA" ]; then
        local m
        m=$(python3 "$FPGA" get 0xE0 2>/dev/null | tail -1)
        echo "  FPGA RES_MODE: ${m:-<读不到>}   (0=1080p60, 1=4K30, 2=4K25)"
        python3 "$FPGA" dump 2>/dev/null | grep -E '帧计数' | sed 's/^/  /'
    fi
    if command -v curl >/dev/null 2>&1; then
        local ai
        ai=$(curl -s -m 4 "http://127.0.0.1:${PORT}/api/ai" 2>/dev/null)
        if [ -n "$ai" ]; then
            echo "  /api/ai     :"
            echo "$ai" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("      ok=%s source=%s  AI帧率=%.1f  检测帧率=%.1f  det=%.1fms  persons=%d" % (
    d.get("ok"), d.get("source"), d.get("fps",0), d.get("fps_det",0),
    d.get("det_ms",0), d.get("persons",0)))' 2>/dev/null || echo "$ai" | head -c 200
        fi
    fi
    echo "=============================================================="
}

#--------------------------------------------------------------- 设模式
set_mode() {
    local want=$1
    if [ ! -f "$FPGA" ]; then
        c_warn "  找不到 $FPGA, 跳过模式设置"
        return 0
    fi
    local m
    m=$(python3 "$FPGA" get 0xE0 2>/dev/null | tail -1 | grep -o '[0-9]\+' | tail -1)
    echo "  当前 RES_MODE = ${m:-?}"
    case "$want" in
        1080|1080p)
            if [ "${m:-x}" != "0" ]; then
                echo "  -> 切 1080p60 (写 0xE0=0)"
                python3 "$FPGA" set 0xE0 0 2>&1 | sed 's/^/     /'
                sleep 3
            else
                echo "  -> 已是 1080p60"
            fi
            ;;
        4k|4K)
            if [ "${m:-x}" != "2" ]; then
                echo "  -> 切 4K25 (写 0xE0=2)"
                python3 "$FPGA" set 0xE0 2 2>&1 | sed 's/^/     /'
                sleep 4
            else
                echo "  -> 已是 4K25"
            fi
            ;;
        *)  c_err "  未知模式: $want (可用: 1080 / 4k)"; return 1;;
    esac

    # 让 RK 侧 media pipeline 与 FPGA 输出尺寸一致（不一致会撕裂）
    local W H
    if [ "$want" = "1080" ] || [ "$want" = "1080p" ]; then W=1920; H=1080; else W=3840; H=2160; fi
    echo "  -> 设 media 通路 ${W}x${H}"
    media-ctl -d /dev/media2 --set-v4l2 "\"m02_back_FPGA-MIPI 9-001a\":0[fmt:YUYV8_2X8/${W}x${H}]" >/dev/null 2>&1
    media-ctl -d /dev/media2 --set-v4l2 "\"rockchip-csi2-dphy3\":0[fmt:YUYV8_2X8/${W}x${H}]"      >/dev/null 2>&1
    media-ctl -d /dev/media2 --set-v4l2 "\"rockchip-mipi-csi2\":0[fmt:YUYV8_2X8/${W}x${H}]"       >/dev/null 2>&1
    echo "     media-ctl 完成"
    return 0
}

#--------------------------------------------------------------- 启动
do_start() {
    echo "=============================================================="
    echo " MIPI 推流 + AI + 云端推送 一键启动"
    echo "   设备 $DEV    端口 $PORT    目标 $MODE    云端 ${SERVER}"
    echo "=============================================================="

    [ -x "$WEB/start_webstream.sh" ] || { c_err "找不到 $WEB/start_webstream.sh"; exit 1; }

    echo "[1/5] 停旧实例"
    stop_all

    echo "[2/5] 设置 FPGA 模式 + media 通路"
    set_mode "$MODE" || exit 1

    echo "[3/5] 启动 web + 集成 AI"
    cd "$WEB" || exit 1
    # V39.1: 必须把当前模式对应的宽高传给 web。
    # 否则 start.sh 4k 把 FPGA/media 设成 3840x2160，而 web 仍按默认
    # 1920x1080 打开 /dev/video22 -> 画面被拉伸/错位。
    local WW HH
    if [ "$MODE" = "1080" ] || [ "$MODE" = "1080p" ]; then WW=1920; HH=1080; else WW=3840; HH=2160; fi
    AI=1 AI_FPS="$AI_FPS" AI_SRC="$AI_SRC" AI_INTERVAL="$AI_INTERVAL" \
        nohup bash ./start_webstream.sh "$DEV" "$PORT" --width "$WW" --height "$HH" >"$LOG" 2>&1 &
    echo "     后台启动中, 日志 $LOG (${WW}x${HH})"

    echo "[4/5] 等待就绪 (最多 25 秒)"
    local i ready=0
    for i in $(seq 1 25); do
        sleep 1
        if listening "$PORT"; then ready=1; break; fi
    done
    if [ "$ready" != "1" ]; then
        c_err "端口 $PORT 未监听, 启动失败。日志尾部:"
        tail -n 30 "$LOG"
        exit 1
    fi
    sleep 3

    echo "[5/5] 拉起云端推送代理"
    cloud_start
    sleep 1

    c_ok "  ✔ 已启动"
    echo ""
    status
    echo ""
    echo "  浏览器打开:"
    echo "    原图/AI 标注 : http://${IP:-<板IP>}:${PORT}/"
    echo "    MJPEG 流     : http://${IP:-<板IP>}:${PORT}/stream"
    echo "    AI 状态 JSON : http://${IP:-<板IP>}:${PORT}/api/ai"
    echo "    云端看板     : ${SERVER}"
    echo ""
    echo "  切画面源: 网页顶栏「原图 / AI 标注」按钮"
    echo "  停止    : start.sh stop   (推流 + 云端推送一起停)"
    echo "  单起云端: start.sh cloud  /  单停: start.sh cloud-stop"
}

case "$MODE" in
    stop|STOP)     stop_all; c_ok "已停止（推流 + 云端推送）"; exit 0;;
    status|STATUS) status;   exit 0;;
    cloud|CLOUD)        cloud_start;  exit 0;;
    cloud-stop|CLOUD-STOP) cloud_stop; exit 0;;
    *)             do_start;;
esac
