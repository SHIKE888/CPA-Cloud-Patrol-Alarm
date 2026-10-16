#!/bin/sh
echo "########## 0) FPGA 现状 ##########"
echo -n "  0xE0(RES_MODE) = "; python3 /root/rk/deploy/fpga_cfg.py get 0xE0 2>&1 | tail -1
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -E "帧计数"

echo ""
echo "########## 1) 停 web+AI (要独占 /dev/video22) ##########"
pkill -f mipi_webstream.py 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 2

echo ""
echo "########## 2) 【1080p 回归】抓裸帧 ##########"
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/1920x1080]'  >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/1920x1080]'  >/dev/null 2>&1
v4l2-ctl -d /dev/video22 --set-fmt-video=width=1920,height=1080,pixelformat=NV16 >/dev/null 2>&1
rm -f /tmp/f1080.raw
timeout 12 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=2 --stream-to=/tmp/f1080.raw 2>&1 | tail -3
ls -l /tmp/f1080.raw
dd if=/tmp/f1080.raw of=/tmp/y1080b.raw bs=2073600 count=1 2>/dev/null
echo -n "  1080p Y 平面 md5 = "; md5sum /tmp/y1080b.raw | cut -d' ' -f1
echo "  (修改前那版是 d896e75f93615adba8e13cdb31b13acf, 这次应不同/内容不同)"

echo ""
echo "########## 3) 切 4K ##########"
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 2 2>&1
sleep 4
echo -n "  0xE0 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xE0 2>&1 | tail -1
echo -n "  0xD4 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD4 2>&1 | tail -1
echo -n "  0xD5 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD5 2>&1 | tail -1

echo ""
echo "########## 4) 设 4K 通路 ##########"
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/3840x2160]'  >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]'  >/dev/null 2>&1
v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
v4l2-ctl -d /dev/video22 --get-fmt-video | head -4

echo ""
echo "########## 5) 抓 3 帧 4K (期望 49766400) ##########"
rm -f /tmp/f4k.raw
timeout 15 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=3 --stream-to=/tmp/f4k.raw 2>&1 | tail -8
SZ=$(stat -c %s /tmp/f4k.raw 2>/dev/null || echo 0)
echo "  >>>>> 4K 抓到 $SZ 字节 <<<<<"
if [ "$SZ" -gt 1000000 ]; then
  dd if=/tmp/f4k.raw of=/tmp/y4k.raw bs=8294400 count=1 2>/dev/null
  ls -l /tmp/y4k.raw
fi

echo ""
echo "########## 6) 恢复 1080p + 起 web/AI ##########"
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 0 2>&1
sleep 3
cd /root/rk/web || exit 1
AI=1 AI_SRC=ai nohup bash ./start_webstream.sh /dev/video22 9012 > /tmp/web_ai.log 2>&1 &
sleep 12
netstat -lntp 2>/dev/null | grep 9012 && echo "  web+AI 已恢复"
curl -s -m 6 http://127.0.0.1:9012/api/ai | head -c 220
echo ""
