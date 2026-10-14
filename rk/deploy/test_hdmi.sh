#!/bin/bash
#=============================================================================
# test_hdmi.sh  —  FPGA(MIPI x4) -> RK3576 -> HDMI 出图测试
#
# 用法:
#   ./test_hdmi.sh              # 自动找节点, 全屏输出到 HDMI
#   ./test_hdmi.sh /dev/video22 # 指定视频节点
#   ./test_hdmi.sh /dev/video22 save   # 只抓一帧存成 PNG 便于离线查看
#=============================================================================
set -u

MODE="${2:-run}"
DEV="${1:-}"

# ---- 自动查找 FPGA 采集节点 ----
find_dev() {
    local v card
    for v in $(ls -1 /dev/video* 2>/dev/null | sort -V); do
        card=$(v4l2-ctl -d "$v" --info 2>/dev/null | sed -n 's/.*Card type *: *//p')
        case "$card" in
            *[Ff][Pp][Gg]*|*[Mm]ilianke*|*rkcif*|*mainpath*|*selfpath*)
                echo "$v"; return 0 ;;
        esac
    done
    return 1
}

if [ -z "$DEV" ]; then
    DEV="$(find_dev)" || true
fi
if [ -z "$DEV" ]; then
    echo "!! 未找到采集节点，请先运行 ./rk_mipi_selftest.sh 排查。"
    exit 1
fi
echo ">>> 使用视频节点: $DEV"
v4l2-ctl -d "$DEV" --get-fmt-video 2>/dev/null

if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
    echo "!! 未安装 gstreamer1.0-tools / gstreamer1.0-plugins-*"
    exit 1
fi

case "$MODE" in
save)
    echo ">>> 抓一帧保存到 /root/frame.png"
    gst-launch-1.0 -e v4l2src device="$DEV" num-buffers=1 \
        ! 'video/x-raw,width=1920,height=1080' \
        ! videoconvert ! pngenc ! filesink location=/root/frame.png
    ls -l /root/frame.png 2>/dev/null || echo "!! 保存失败，检查 pngenc 插件"
    ;;
run)
    # 优先 kmssink (直接走 DRM/KMS 上屏到 HDMI, 延迟最低)
    echo ">>> 输出到 HDMI (kmssink, 4 lane 1920x1080@60)"
    exec gst-launch-1.0 v4l2src device="$DEV" \
        ! kmssink
    ;;
*)
    echo "未知模式: $MODE  (可用: run | save)"
    exit 1
    ;;
esac
