#!/bin/sh
# 强制走一次 4K -> 1080p -> 4K 的模式切换, 逼 FPGA 重写整张传感器寄存器表
# 目的: 区分"上电没写表" 和 "写了但传感器钳住 VMAX"
F=/root/rk/deploy/fpga_cfg.py
DEV=/dev/video22

meas() {  # $1=帧数  $2=标签
  T0=$(date +%s%N)
  timeout 30 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=$1 --stream-to=/dev/null > /tmp/m.txt 2>&1
  RC=$?
  T1=$(date +%s%N)
  MS=$(( (T1-T0)/1000000 ))
  V=$(grep -oE '[0-9]+\.[0-9]+ fps' /tmp/m.txt 2>/dev/null | tail -1)
  echo "  [$2] rc=$RC ${MS}ms => $V"
}

echo "########## A) 停 web ##########"
pkill -f 'mipi_webstream\.py' 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 3

echo ""
echo "########## B) 切换前 4K 帧率 ##########"
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
meas 30 "切换前4K"

echo ""
echo "########## C) 强制 4K -> 1080p ##########"
python3 $F set 0xE0 0 >/dev/null 2>&1
sleep 5
echo -n "  RES_MODE="; python3 $F get 0xE0 2>&1 | tail -1
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
v4l2-ctl -d $DEV --set-fmt-video=width=1920,height=1080,pixelformat=NV16 >/dev/null 2>&1
meas 100 "1080p"

echo ""
echo "########## D) 1080p -> 4K (强制重写整表) ##########"
python3 $F set 0xE0 2 >/dev/null 2>&1
sleep 5
echo -n "  RES_MODE="; python3 $F get 0xE0 2>&1 | tail -1
a=$(python3 $F get 0xD4 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
b=$(python3 $F get 0xD5 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
echo "  行组数 = 0x$b$a"
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
meas 40 "切换后4K"
sleep 2
meas 40 "切换后4K(2)"

echo ""
echo "########## E) dmesg ##########"
dmesg 2>/dev/null | grep -iE "ERR|ecc|crc|timeout|size" | tail -8

echo ""
echo "########## F) 恢复推流 ##########"
/usr/local/bin/start.sh 4k > /tmp/_r6.log 2>&1
grep -E "已启动|RES_MODE" /tmp/_r6.log | head -4
echo ""
echo "########## 完成 ##########"
