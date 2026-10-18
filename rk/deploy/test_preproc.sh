#!/bin/bash
#=============================================================================
# test_preproc.sh —— 验证 FPGA 预处理（高级 8 种 + 初级 4 种组合）的实际画面
#
# 对每种模式: 通过 I2C 写 ADV_MODE / BASIC_EN -> 抓若干帧 -> 存 PNG -> 自动分析特征。
#
# 用法: sh /root/rk/deploy/test_preproc.sh
#   KEEP=1 保留图片（默认测完会删掉临时目录）
#   OUT_DIR=/xxx 指定输出目录（默认 /tmp/preproc_test）
#
# 注意:
#   · 预处理配置走 I2C (0x40), 与视频流互不干扰, 可以边出图边切模式。
#   · 抓帧会临时占用 /dev/video22, 所以要先把推流进程停掉。
#   · pkill 的模式写成 'mipi_web[s]tream' —— 否则 pkill 会匹配到自己所在的
#     这条 ssh 命令行, 把当前 shell 一起杀掉。
#=============================================================================
set -u

DEV=/dev/video22
OUT=${OUT_DIR:-/tmp/preproc_test}
CFG="/usr/bin/python3 /root/rk/deploy/fpga_cfg.py"
PY=/opt/miniforge3/envs/mlk-ov/bin/python

mkdir -p "$OUT"

echo "== 让出 $DEV =="
pkill -f 'mipi_web[s]tream' 2>/dev/null && echo "  已停止 mipi_webstream"
pkill -f 'gst-launch' 2>/dev/null
sleep 1

echo ""
echo "== 确认 PP_EN 打开 =="
$CFG set 0xB0 1

for m in 0 1 2 3 4 5 6 7 8; do
    echo ""
    echo "=================== ADV_MODE = $m ==================="
    $CFG mode "$m" || true
    sleep 1

    rm -f "$OUT/m${m}_"*.png
    timeout 45 gst-launch-1.0 -e v4l2src device="$DEV" num-buffers=12 \
        ! 'video/x-raw,width=1920,height=1080' \
        ! videoconvert ! pngenc \
        ! multifilesink location="$OUT/m${m}_%02d.png" >/dev/null 2>&1

    n=$(ls -1 "$OUT/m${m}_"*.png 2>/dev/null | wc -l)
    echo "  抓到 $n 帧"
    last=$(ls -1 "$OUT/m${m}_"*.png 2>/dev/null | tail -1)
    if [ -n "$last" ]; then
        cp "$last" "$OUT/mode${m}.png"
        "$PY" /root/rk/deploy/analyze_preproc.py "$OUT/mode${m}.png"
    else
        echo "  !! 抓帧失败 —— 检查 gstreamer 插件 (pngenc/multifilesink/videoconvert)"
    fi
done

echo ""
echo "== 恢复: 关闭预处理, 直通原图 =="
$CFG set 0xB0 0
$CFG set 0xF0 0
$CFG get 0xB0
$CFG get 0xF0
echo ""
if [ "${KEEP:-0}" = "1" ]; then
    echo "结果图片保留在: $OUT"
else
    rm -rf "$OUT"
    echo "临时图片已删除 (KEEP=1 可保留)"
fi
