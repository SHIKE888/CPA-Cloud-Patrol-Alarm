#!/bin/sh
# 零烧录判决: 是传感器只给 12.5fps, 还是 FPGA 只能吐 12.5fps
# 原理: 把 VTC(读侧) 改成 30fps (RES_MODE=1)
#   若 rkcif 报到 ~30  => 读侧/推送链路有能力, 12.5 的瓶颈在【传感器】
#                         (读侧可以重复读同一 bank, 所以能发满 30)
#   若 rkcif 仍是 12.5 => 瓶颈在【推送链路】(packer/TX/dbuf 读)
F=/root/rk/deploy/fpga_cfg.py
DEV=/dev/video22

meas() {
  T0=$(date +%s%N)
  timeout 40 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=$1 --stream-to=/dev/null > /tmp/m.txt 2>&1
  RC=$?
  T1=$(date +%s%N)
  MS=$(( (T1-T0)/1000000 ))
  V=$(grep -oE '[0-9]+\.[0-9]+ fps' /tmp/m.txt 2>/dev/null | tail -1)
  echo "  [$2] rc=$RC ${MS}ms => $V"
}

pkill -f 'mipi_webstream\.py' 2>/dev/null
sleep 3

echo "########## A) 当前 4K25 (RES_MODE=2, VTC 24.99fps) ##########"
python3 $F set 0xE0 2 >/dev/null 2>&1
sleep 4
echo -n "  RES_MODE="; python3 $F get 0xE0 2>&1 | tail -1
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
meas 40 "4K25"

echo ""
echo "########## B) 切 4K30 (RES_MODE=1, VTC 30.0fps) ##########"
python3 $F set 0xE0 1 >/dev/null 2>&1
sleep 4
echo -n "  RES_MODE="; python3 $F get 0xE0 2>&1 | tail -1
a=$(python3 $F get 0xD4 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
b=$(python3 $F get 0xD5 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
echo "  行组数 = 0x$b$a"
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
meas 60 "4K30-VTC"
meas 60 "4K30-VTC(2)"

echo ""
echo "########## C) 切回 4K25 ##########"
python3 $F set 0xE0 2 >/dev/null 2>&1
sleep 4
echo -n "  RES_MODE="; python3 $F get 0xE0 2>&1 | tail -1

echo ""
echo "########## D) dmesg ##########"
echo -n "  ECC: "; dmesg 2>/dev/null | grep -c "ecc"
echo -n "  CRC: "; dmesg 2>/dev/null | grep -c "crc"

echo ""
echo "########## E) 恢复推流 ##########"
/usr/local/bin/start.sh 4k > /tmp/_r9.log 2>&1
grep -E "已启动|RES_MODE" /tmp/_r9.log | head -4
echo ""
echo "########## 完成 ##########"
