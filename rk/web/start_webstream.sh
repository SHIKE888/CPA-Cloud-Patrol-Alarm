#!/bin/bash
#=============================================================================
# start_webstream.sh —— 一键启动 MIPI 网页推流服务
#
# 用法:
#   ./start_webstream.sh                      # 默认 /dev/video22 : 9012
#   ./start_webstream.sh /dev/video22 9012
#   ./start_webstream.sh /dev/video22 9012 --stream-width 960 --backend opencv
#
# 指定解释器:
#   PYTHON=/opt/miniforge3/envs/mlk-ov/bin/python ./start_webstream.sh
#
# 启动后:
#   PC 浏览器打开 mipi_viewer.html, 填 RK 的 IP:9012 即可看画面并调参
#   也可以直接在 RK 上打开 http://<RK的IP>:9012/
#=============================================================================
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

DEV="${1:-/dev/video22}";  [ $# -ge 1 ] && shift
PORT="${1:-9012}";         [ $# -ge 1 ] && shift

# ---- 选 Python 解释器 ----
# 本板 OpenCV(cv2 5.0) 装在 conda 环境 mlk-ov 里; 系统 python3 没有 cv2 但有 gi/Gst。
# 优先挑 "能 import cv2" 的解释器(软件调参最全), 找不到再退回系统 python3(走 GStreamer)。
if [ -z "${PYTHON:-}" ]; then
    PYTHON=""
    for cand in /opt/miniforge3/envs/mlk-ov/bin/python \
                /opt/miniforge3/envs/*/bin/python \
                /opt/miniconda3/envs/*/bin/python \
                python3; do
        command -v "$cand" >/dev/null 2>&1 || continue
        if "$cand" -c 'import cv2' >/dev/null 2>&1; then
            PYTHON="$cand"
            break
        fi
    done
    [ -n "$PYTHON" ] || PYTHON=python3
    command -v "$PYTHON" >/dev/null 2>&1 || { echo "!! 未找到可用的 Python"; exit 1; }
fi

LISTEN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

# ---- 确保 YUV->BGR 的 C 加速库存在 ----
# 没有它的话服务器会退回 numpy 版: 单线程 1920x1080 要 45~67ms,
# 直接把 1080p60 拖成 22fps。编译只要 1 秒, 所以顺手做掉。
YUVCONV="$DIR/libyuvconv.so"
if [ ! -f "$YUVCONV" ] && command -v gcc >/dev/null 2>&1; then
    echo "编译 C 加速库 libyuvconv.so ..."
    "$DIR/build_yuvconv.sh" >/dev/null 2>&1 || echo "!! 编译失败, 将使用 numpy 版 (较慢)"
fi
if [ -f "$YUVCONV" ]; then
    ACCEL="已启用 (libyuvconv.so)"
else
    ACCEL="未启用 —— 会慢很多, 请运行 ./build_yuvconv.sh"
fi

echo "=============================================================="
echo " MIPI 网页推流"
echo "   Python : $PYTHON"
echo "   设备   : $DEV"
echo "   端口   : $PORT"
echo "   地址   : http://${LISTEN_IP:-<本机IP>}:$PORT/"
echo "   加速   : C 色彩转换 $ACCEL"
echo "   流水线 : 采集1线程 / 转换4线程 / 编码3线程, 默认绑大核"

# ---- 可选: AI 标注叠加 ----
# AI=1 时启用(人体框 / 姿态骨架 / 危险动作), 画面源在网页顶栏与 AI 页签里切。
# AI 是挂在编码线程上的, 切回"原图"就没有额外开销。
AI_ARGS=""
if [ "${AI:-0}" = "1" ]; then
    AI_ARGS="--ai --ai-fps ${AI_FPS:-30} --ai-source ${AI_SRC:-raw} --ai-kpt-margin ${AI_MARGIN:-0.15} --ai-kpt-max-dist ${AI_MAXDIST:-1.2} --ai-det-interval ${AI_INTERVAL:-2}"
    [ -n "${AI_ZONE:-}" ] && AI_ARGS="$AI_ARGS --ai-zone ${AI_ZONE}"
    echo "   AI     : 已启用 (画面源 ${AI_SRC:-raw}, AI ${AI_FPS:-30} fps, 关节范围 ±${AI_MARGIN:-0.15}, 检测间隔 ${AI_INTERVAL:-2})"
else
    echo "   AI     : 未启用 (加 AI=1 可开启人体框/骨架/危险动作叠加)"
fi
echo "=============================================================="

# -u: 关掉 python 的 stdout 块缓冲。重定向到日志文件时 stdout 不是 tty,
#     不关缓冲的话启动横幅(含 FPGA I2C 探测结果)会迟迟不落盘, 不好排查。
exec "$PYTHON" -u "$DIR/mipi_webstream.py" --device "$DEV" --port "$PORT" $AI_ARGS "$@"
