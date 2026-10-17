#!/bin/sh
# V32 4K 纯传输 demo 验证: 抓内置图案, 不看摄像头
D=/root/rk/deploy
CFG="python3 $D/fpga_cfg.py"

echo "########## 0) FPGA 状态 (V31: 上电即 4K) ##########"
echo -n "  RES_MODE = "; $CFG get 0xE0 2>&1 | tail -1
$CFG dump 2>&1 | grep -E "帧计数"

echo ""
echo "########## 1) 停 web (独占 video22) ##########"
pkill -f mipi_webstream.py 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 2

echo ""
echo "########## 2) RK 侧按 4K 接收 (只是接收端配置, 不切 FPGA) ##########"
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1 && echo "  sensor:0 ok" || echo "  sensor:0 FAIL"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]'  >/dev/null 2>&1 && echo "  dphy3:0 ok"  || echo "  dphy3:0 FAIL"
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]'  >/dev/null 2>&1 && echo "  csi2:0 ok"   || echo "  csi2:0 FAIL"
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | head -4

echo ""
echo "########## 3) 抓 3 帧 (期望 49766400 字节) ##########"
dmesg -c >/dev/null 2>&1
rm -f /tmp/tpg.raw
timeout 15 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=3 --stream-to=/tmp/tpg.raw 2>&1 | tail -6
SZ=$(stat -c %s /tmp/tpg.raw 2>/dev/null || echo 0)
echo "  >>>>> 抓到 $SZ 字节 <<<<<"
if [ "$SZ" -gt 1000000 ]; then
  dd if=/tmp/tpg.raw of=/tmp/y_tpg.raw bs=8294400 count=1 2>/dev/null
  echo -n "  Y md5 = "; md5sum /tmp/y_tpg.raw | cut -d' ' -f1
fi

echo ""
echo "########## 4) dmesg ##########"
dmesg 2>&1 | grep -iE "rkcif|mipi3|dphy3|milianke" | tail -10
