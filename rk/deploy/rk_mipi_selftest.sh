#!/bin/bash
#=============================================================================
# rk_mipi_selftest.sh
#   在 RK3576 (Debian) 上自检 FPGA -> MIPI -> RK 链路是否正常
#   不依赖显示器，先确认驱动/设备节点采集通路 OK，再去看 HDMI。
#
# 用法:
#   chmod +x rk_mipi_selftest.sh
#   ./rk_mipi_selftest.sh
#=============================================================================
set -u

echo "=============================================================="
echo " FPGA(MIPI x4) -> RK3576 MIPI-CSI3 链路自检"
echo "=============================================================="

#------------------------------------------------------------------
# 1. 确认 FPGA bit 已烧写 & 板上电顺序正确
#------------------------------------------------------------------
echo ""
echo ">>> [1/6] 检查 boot 与内核版本"
echo "    uname -r : $(uname -r)"
if [ -f /proc/device-tree/model ]; then
    echo "    board    : $(tr -d '\0' < /proc/device-tree/model)"
fi

#------------------------------------------------------------------
# 2. 确认设备树里 FPGA 虚拟摄像头节点已经使能
#------------------------------------------------------------------
echo ""
echo ">>> [2/6] 检查设备树 fpga@1a (milianke,fpga-virtual) 节点"
FOUND_DT=0
for n in /proc/device-tree/i2c@*/fpga@1a /proc/device-tree/soc/i2c@*/fpga@1a; do
    [ -e "$n" ] || continue
    FOUND_DT=1
    echo "    节点: $n"
    [ -f "$n/compatible" ] && echo "    compatible : $(tr -d '\0' < "$n/compatible")"
    [ -f "$n/status" ]     && echo "    status     : $(tr -d '\0' < "$n/status")"
    [ -f "$n/mipi-en-gpios" ] && echo "    mipi-en    : 已定义 (FPGA D-PHY 发送使能)"
done
if [ "$FOUND_DT" = "0" ]; then
    echo "    !! 未找到 fpga@1a 节点。请确认已烧写本项目提供的 boot.img"
    echo "       (设备树包含 rk03/csi-imx415-2.dtsi 的 FPGA 虚拟摄像头配置)"
fi

#------------------------------------------------------------------
# 3. 确认驱动已经注册成功
#------------------------------------------------------------------
echo ""
echo ">>> [3/6] 检查 milianke_mipi 驱动与 I2C 绑定"
if dmesg 2>/dev/null | grep -q "milianke MIPI sensor registered"; then
    dmesg | grep -i "milianke" | tail -5
else
    echo "    未在 dmesg 中找到注册信息。可能驱动为 .ko，尝试 insmod："
    KO=$(find /root /home /lib/modules -name 'milianke_mipi.ko' 2>/dev/null | head -1)
    if [ -n "$KO" ]; then
        echo "    发现 $KO ，执行 insmod"
        insmod "$KO" && echo "    insmod OK" || echo "    insmod 失败"
    else
        echo "    !! 未找到 milianke_mipi.ko；若内核已内置该驱动则忽略此提示"
    fi
fi
echo "    --- I2C / V4L2 相关内核日志 ---"
dmesg 2>/dev/null | grep -iE "milianke|rkcif|rkisp|mipi.*csi|dphy" | tail -20

#------------------------------------------------------------------
# 4. 列出视频节点
#------------------------------------------------------------------
echo ""
echo ">>> [4/6] 查找 V4L2 视频节点"
VIDEO_DEV=""
for v in $(ls -1 /dev/video* 2>/dev/null | sort -V); do
    info=$(v4l2-ctl -d "$v" --info 2>/dev/null)
    card=$(echo "$info" | sed -n 's/.*Card type *: *//p')
    if echo "$card" | grep -qiE "fpga|milianke|rkcif|mainpath|selfpath"; then
        printf "    %-16s %s\n" "$v" "$card"
        [ -z "$VIDEO_DEV" ] && VIDEO_DEV="$v"
    fi
done
if [ -z "$VIDEO_DEV" ]; then
    echo "    !! 没有找到可用采集节点。先检查 [2]/[3] 两项。"
    exit 1
fi
echo "    选用: $VIDEO_DEV"
echo "    --- 支持的格式 ---"
v4l2-ctl -d "$VIDEO_DEV" --list-formats-ext 2>/dev/null | head -30

#------------------------------------------------------------------
# 5. 抓 10 帧验证采集链路 (不依赖 HDMI/显示器)
#------------------------------------------------------------------
echo ""
echo ">>> [5/6] 采集 10 帧 (fakesink, 验证 FPGA->MIPI->RK 数据通路)"
if command -v gst-launch-1.0 >/dev/null 2>&1; then
    gst-launch-1.0 -q v4l2src device="$VIDEO_DEV" num-buffers=10 \
        ! 'video/x-raw,width=1920,height=1080' ! fakesink 2>&1 | tail -20
    echo "    若上方无 ERROR，说明采集通路 OK"
else
    echo "    !! 未安装 gstreamer，改用 v4l2-ctl 抓 1 帧到文件"
    v4l2-ctl -d "$VIDEO_DEV" \
        --set-fmt-video=width=1920,height=1080,pixelformat=YUYV \
        --stream-mmap --stream-count=1 --stream-to=/tmp/frame.raw 2>&1 | tail -5
    echo "    抓帧文件: /tmp/frame.raw  (1920x1080 YUYV = 4147200 字节)"
    ls -l /tmp/frame.raw 2>/dev/null
fi

#------------------------------------------------------------------
# 6. 显示到 HDMI
#------------------------------------------------------------------
echo ""
echo ">>> [6/6] 输出到 HDMI (kmssink)"
echo "    手动执行以下任一命令:"
echo "      gst-launch-1.0 v4l2src device=$VIDEO_DEV ! kmssink"
echo "      gst-launch-1.0 v4l2src device=$VIDEO_DEV ! videoconvert ! kmssink"
echo ""
echo "    若 HDMI 无画面，检查:"
echo "      1) HDMI 线接在 RK3576 HDMI OUT，显示器输入源选对"
echo "      2) cat /sys/class/drm/card*-HDMI-A-1/status   应为 connected"
echo "      3) 指定 connector:  kmssink connector-id=<id>  (modetest -c 查询)"
echo ""
echo "=============================================================="
echo " 自检结束"
echo "=============================================================="
