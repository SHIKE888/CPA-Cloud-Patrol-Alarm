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
#    3) 叫 start.sh cloud 把云端推送代理拉起来（幂等）
#    4) exec start_webstream.sh（内部最后一行就是 exec python）
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

# ---- 0. CPU 调频器 ondemand -> performance ----
#  板子是 8 核异构: cpu0-3 = A53@1.92G, cpu4-7 = A72@2.11G, 默认全是 ondemand。
#
#  板上 A/B 实测 (双目 3840x1080 + AI + 深度全开, 2 客户端):
#    指标        ondemand   performance
#    video fps     27.9  ->   29.3
#    AI fps        17.9  ->   20.4
#    det_ms        78.3  ->   18.4     <- 4.2 倍
#    run_ms       101.4  ->   19.4
#    depth ms     113.8  ->   87.8
#    loadavg       7.88  ->   6.11
#    SoC 温度     62.8C  ->   59.2C     <- 反而更低
#
#  为什么 ondemand 更慢: 它要"采样 -> 判定 -> 升频", 这条延迟落在 33ms 的
#  帧间隔里就是一次掉帧; 而且负载在阈值附近来回跳, 频率也跟着抖。
#  常频之后没有升降频的空转, 所以温度反而降了。
#
#  (只写 scaling_governor, 不动 min/max freq, 不用 userspace 锁频)
for _g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$_g" ] || continue
    cur=$(cat "$_g" 2>/dev/null)
    [ "$cur" = "performance" ] || echo performance > "$_g" 2>/dev/null
done
unset _g cur
log "CPU governor -> $(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_governor 2>/dev/null)"

# ---- 0.5 兜底：点亮四色灯的蓝灯 ----
#  正常路径是 udev 在 CH340 枚举时（开机 2~4 秒）就点亮，比本脚本早约 20 秒。
#  这里只是保险：udev 规则没装/没触发时，服务启动时补一次，避免这 20 秒全黑。
#  AlarmLight 稍后接管时会再发一次蓝灯，两者幂等。
if [ -x /root/rk/deploy/lamp_boot.sh ]; then
    /root/rk/deploy/lamp_boot.sh 2>/dev/null || true
fi

# ---- 1. 等设备节点就绪（I2C 桥 / video 节点可能比本服务晚出现） ----
for i in $(seq 1 40); do
    [ -e /dev/i2c-9 ] && [ -e "$DEV" ] && break
    sleep 0.5
done
if [ ! -e "$DEV" ]; then
    log "警告: $DEV 不存在，仍然尝试启动（采集线程会自己重试）"
fi

# ---- 2. 复位 FPGA：只有当模式不是目标值时才写 0xE0 ----
#   ⚠ 开机时 FPGA 刚加载 bit，0xE0 本来就是默认值(0)。
#     这时再写一次同值会触发 res_chg 复位窗(500ms + sensor 重下整表)，
#     把 sensor 的**上电初始化时序**打乱 -> MIPI_CSI2 ECC 刷屏、收不到帧。
#     start.sh 的做法是“已是目标模式就跳过”，这里必须一致。
if [ -f "$FPGA" ]; then
    CUR=$(python3 "$FPGA" get 0xE0 2>/dev/null | sed 's/.*(\([0-9][0-9]*\)).*/\1/')
    if [ "${CUR:-x}" = "$RES" ]; then
        log "FPGA 已是 RES_MODE=$RES，跳过复位（保持上电时序）"
    else
        log "复位 FPGA: RES_MODE=$CUR -> $RES"
        python3 "$FPGA" set 0xE0 "$RES" || log "写 0xE0 失败（继续）"
        # 4K 的 sensor 初始化更慢
        if [ "$RES" = "2" ] || [ "$RES" = "1" ]; then sleep 8; else sleep 5; fi
    fi
else
    log "找不到 $FPGA，跳过 FPGA 复位"
fi

# ---- 3. 配 media 通路（必须从 sensor subdev 开始改） ----
log "配置 media 通路 ${W}x${H}"
media-ctl -d /dev/media2 --set-v4l2 "\"m02_back_FPGA-MIPI 9-001a\":0[fmt:YUYV8_2X8/${W}x${H}]" >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 "\"rockchip-csi2-dphy3\":0[fmt:YUYV8_2X8/${W}x${H}]"      >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 "\"rockchip-mipi-csi2\":0[fmt:YUYV8_2X8/${W}x${H}]"       >/dev/null 2>&1

# ---- 4. 拉起云端推送代理（与网页推流同一个入口：start.sh cloud）----
#   为什么在这里而不是再写一份命令：代理的启动/重试/日志规则只在 start.sh
#   里维护一份；本脚本只负责“开机时叫一声”。有 systemd 单元时 start.sh 会
#   交给 systemd（幂等：已在运行就直接返回，不会起第二个进程）。
START=${START:-/root/rk/deploy/start.sh}
if [ -f "$START" ]; then
    log "拉起云端推送代理 (start.sh cloud)"
    CLOUD=${CLOUD:-1} PORT="$PORT" bash "$START" cloud 2>&1 | sed 's/^/[cloud] /'
else
    log "警告: 找不到 $START，跳过云端推送"
fi

# ---- 5. 前台运行推流服务（exec：PID 不变，systemd 能直接管理） ----
log "启动推流服务 $DEV :$PORT ${W}x${H}"
cd "$WEB" || exit 1
exec bash ./start_webstream.sh "$DEV" "$PORT" --width "$W" --height "$H"
