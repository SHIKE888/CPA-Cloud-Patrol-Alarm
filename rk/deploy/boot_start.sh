#!/bin/bash
#=============================================================================
#  boot_start.sh —— 开机自启入口（由 systemd 调用，前台运行）
#
#  为什么不让 systemd 直接跑 start.sh：
#    start.sh 用 nohup 把 python 丢到后台，脚本自己退出。systemd 就看不到
#    真正的服务进程了（状态、重启、日志都不好管）。
#  这里只做“上电初始化”三件事，然后把 python 用 exec 换成前台进程：
#    1) 复位 FPGA（写 0xE0，等 sensor 重新锁相）
#    2) 配 RK 侧 media 通路（3 个 pad）
#    3) exec start_webstream.sh（内部最后一行就是 exec python）
#
#  可用环境变量（systemd unit 里设置）：
#    RES=0|2     0=1080p60（默认）, 2=4K25
#    W/H         输出尺寸，必须与 RES 对应
#    DEV/PORT    设备与端口
#    AI=1        启用 AI 标注（默认开）
#=============================================================================
set -u

DEV=${DEV:-/dev/video22}
PORT=${PORT:-9012}
RES=${RES:-0}
FPGA=${FPGA:-/root/rk/deploy/fpga_cfg.py}
WEB=${WEB:-/root/rk/web}

if [ "$RES" = "2" ] || [ "$RES" = "1" ]; then
    W=${W:-3840}; H=${H:-2160}
else
    W=${W:-1920}; H=${H:-1080}
fi

log() { echo "[boot] $*"; }

# ---- 1. 等设备节点就绪（I2C 桥 / video 节点可能比本服务晚出现） ----
for i in $(seq 1 40); do
    [ -e /dev/i2c-9 ] && [ -e "$DEV" ] && break
    sleep 0.5
done
if [ ! -e "$DEV" ]; then
    log "警告: $DEV 不存在，仍然尝试启动（采集线程会自己重试）"
fi

# ---- 2. 复位 FPGA：写 0xE0 会让 sensor 重下整张初始化表并重新锁相 ----
if [ -f "$FPGA" ]; then
    log "复位 FPGA: RES_MODE=$RES"
    python3 "$FPGA" set 0xE0 "$RES" || log "写 0xE0 失败（继续）"
    # 1080p 仍需 5s；4K 的 sensor 初始化更慢，给 8s
    if [ "$RES" = "2" ] || [ "$RES" = "1" ]; then sleep 8; else sleep 5; fi
else
    log "找不到 $FPGA，跳过 FPGA 复位"
fi

# ---- 3. 配 media 通路（必须从 sensor subdev 开始改） ----
log "配置 media 通路 ${W}x${H}"
media-ctl -d /dev/media2 --set-v4l2 "\"m02_back_FPGA-MIPI 9-001a\":0[fmt:YUYV8_2X8/${W}x${H}]" >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 "\"rockchip-csi2-dphy3\":0[fmt:YUYV8_2X8/${W}x${H}]"      >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 "\"rockchip-mipi-csi2\":0[fmt:YUYV8_2X8/${W}x${H}]"       >/dev/null 2>&1

# ---- 4. 前台运行推流服务（exec：PID 不变，systemd 能直接管理） ----
log "启动推流服务 $DEV :$PORT ${W}x${H}"
cd "$WEB" || exit 1
exec bash ./start_webstream.sh "$DEV" "$PORT" --width "$W" --height "$H"
