#!/bin/sh
# V30 三步验证。基准 = 刚烧完(FPGA 上电初值)的 1080p，不允许用"切换后"的当基准。
D=/root/rk/deploy
CFG="python3 $D/fpga_cfg.py"

set_lane() {   # $1=W $2=H
    media-ctl -d /dev/media2 --set-v4l2 "\"m02_back_FPGA-MIPI 9-001a\":0[fmt:YUYV8_2X8/$1x$2]" >/dev/null 2>&1
    media-ctl -d /dev/media2 --set-v4l2 "\"rockchip-csi2-dphy3\":0[fmt:YUYV8_2X8/$1x$2]"      >/dev/null 2>&1
    media-ctl -d /dev/media2 --set-v4l2 "\"rockchip-mipi-csi2\":0[fmt:YUYV8_2X8/$1x$2]"       >/dev/null 2>&1
    v4l2-ctl -d /dev/video22 --set-fmt-video=width=$1,height=$2,pixelformat=NV16 >/dev/null 2>&1
}

grab() {       # $1=tag $2=width $3=height $4=count $5=Y字节数
    rm -f /tmp/$1.raw
    timeout 15 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=$4 --stream-to=/tmp/$1.raw 2>&1 | tail -3
    SZ=$(stat -c %s /tmp/$1.raw 2>/dev/null || echo 0)
    echo "  >>> $1 抓到 $SZ 字节"
    if [ "$SZ" -gt 1000000 ]; then
        dd if=/tmp/$1.raw of=/tmp/y_$1.raw bs=$5 count=1 2>/dev/null
        echo -n "      Y md5 = "; md5sum /tmp/y_$1.raw | cut -d' ' -f1
    fi
}

echo "############ 0) 初始状态 (刚烧完) ############"
pkill -f mipi_webstream.py 2>/dev/null && echo "  停掉 web" || echo "  web 未运行"
sleep 2
echo -n "  RES_MODE = "; $CFG get 0xE0 2>&1 | tail -1
$CFG dump 2>&1 | grep -E "帧计数"

echo ""
echo "############ 1) 刚上电 1080p (基准) ############"
set_lane 1920 1080
grab s1 1920 1080 2 2073600

echo ""
echo "############ 2) 切 4K, 抓 3 帧 (期望 49766400) ############"
$CFG set 0xE0 2 2>&1
sleep 4
echo -n "  RES_MODE = "; $CFG get 0xE0 2>&1 | tail -1
echo -n "  0xD4/0xD5 = "; $CFG get 0xD4 2>&1 | tail -1
$CFG dump 2>&1 | grep -E "帧计数"
set_lane 3840 2160
grab s2 3840 2160 3 8294400

echo ""
echo "############ 3) 切回 1080p (主目标: 不能错位/死机) ############"
$CFG set 0xE0 0 2>&1
sleep 5
echo -n "  RES_MODE 回读 = "; $CFG get 0xE0 2>&1 | tail -1
echo -n "  心跳 = "; $CFG heartbeat 2>&1 | tail -1
$CFG dump 2>&1 | grep -E "帧计数"
set_lane 1920 1080
grab s3 1920 1080 2 2073600

echo ""
echo "############ 4) 恢复 web+AI ############"
start.sh 2>&1 | tail -12
