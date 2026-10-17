#!/bin/sh
# 对照组: 4K 与 1080p 各测一次, 看是不是全局 2x 偏差
F=/root/rk/deploy/fpga_cfg.py
DEV=/dev/video22

meas() {  # $1=帧数  $2=标签
  T0=$(date +%s%N)
  timeout 60 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=$1 --stream-to=/dev/null > /tmp/m.txt 2>&1
  RC=$?
  T1=$(date +%s%N)
  MS=$(( (T1-T0)/1000000 ))
  V=$(grep -oE '[0-9]+\.[0-9]+ fps' /tmp/m.txt 2>/dev/null | tail -1)
  echo "  [$2] rc=$RC  ${1}帧 ${MS}ms  => v4l2 自报 $V"
}

echo "########## A) 停 web ##########"
pkill -f 'mipi_webstream\.py' 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 3

echo ""
echo "########## B) 当前 4K (RES_MODE=2) ##########"
echo -n "  RES_MODE="; python3 $F get 0xE0 2>&1 | tail -1
echo -n "  行组数="; python3 $F get 0xD4 2>&1 | tail -1
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
meas 40 "4K"

echo ""
echo "########## C) 切 1080p (RES_MODE=0) ##########"
python3 $F set 0xE0 0 >/dev/null 2>&1
sleep 4
echo -n "  RES_MODE="; python3 $F get 0xE0 2>&1 | tail -1
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
v4l2-ctl -d $DEV --set-fmt-video=width=1920,height=1080,pixelformat=NV16 >/dev/null 2>&1
echo -n "  行组数="; python3 $F get 0xD4 2>&1 | tail -1
meas 120 "1080p"

echo ""
echo "########## D) 切回 4K ##########"
python3 $F set 0xE0 2 >/dev/null 2>&1
sleep 4
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NVS16 >/dev/null 2>&1
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
echo -n "  RES_MODE="; python3 $F get 0xE0 2>&1 | tail -1
echo -n "  行组数="; python3 $F get 0xD4 2>&1 | tail -1

echo ""
echo "########## E) dmesg ##########"
dmesg 2>/dev/null | grep -iE "ERR|ecc|crc|vblank|size" | tail -8

echo ""
echo "########## F) 恢复推流 ##########"
/usr/local/bin/start.sh 4k > /tmp/_r4.log 2>&1
grep -E "已启动|RES_MODE" /tmp/_r4.log | head -4
echo ""
echo "########## 完成 ##########"
