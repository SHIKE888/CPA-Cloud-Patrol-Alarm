#!/bin/sh
# 老老实实把"现在"的状态测出来: 不预设结论
echo "########## A) FPGA 现在是什么状态 ##########"
echo -n "  0xE0 RES_MODE = "; python3 /root/rk/deploy/fpga_cfg.py get 0xE0 2>&1 | tail -1
echo -n "  0xD4 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD4 2>&1 | tail -1
echo -n "  0xD5 = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD5 2>&1 | tail -1
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -E "帧计数|HEARTBEAT"

echo ""
echo "########## B) dmesg 有没有报错 ##########"
dmesg 2>/dev/null | grep -iE "rkcif|mipi3|dphy3|milianke|size|err|timeout" | tail -20

echo ""
echo "########## C) 现在谁在跑 ##########"
ps aux | grep -E 'mipi_webstream|ai_webstream' | grep -v grep
netstat -lntp 2>/dev/null | grep -E "9012|9013"

echo ""
echo "########## D) 停 web, 抓【当前模式】的裸帧 ##########"
pkill -f mipi_webstream.py 2>/dev/null && echo "  已停 web" || echo "  web 未运行"
sleep 2
echo "--- 当前 /dev/video22 格式 ---"
v4l2-ctl -d /dev/video22 --get-fmt-video | head -4

echo ""
echo "########## E) 强制按 1080p 抓 (2 帧) ##########"
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-csi2-dphy3":0[fmt:YUYV8_2X8/1920x1080]'  >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/1920x1080]'  >/dev/null 2>&1
v4l2-ctl -d /dev/video22 --set-fmt-video=width=1920,height=1080,pixelformat=NV16 >/dev/null 2>&1
rm -f /tmp/f1080.raw
timeout 12 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=2 --stream-to=/tmp/f1080.raw 2>&1 | tail -3
ls -l /tmp/f1080.raw
dd if=/tmp/f1080.raw of=/tmp/y1080c.raw bs=2073600 count=1 2>/dev/null
echo -n "  帧0 Y md5 = "; md5sum /tmp/y1080c.raw | cut -d' ' -f1
echo "  (刚才那次是 ec6572d654350e0ac34cfc98143d3e4f)"

echo ""
echo "########## F) 再抓一次(第二帧) 看是否帧间不同 ##########"
dd if=/tmp/f1080.raw of=/tmp/y1080c2.raw bs=2073600 skip=1 count=1 2>/dev/null
echo -n "  帧1 Y md5 = "; md5sum /tmp/y1080c2.raw | cut -d' ' -f1

echo ""
echo "########## G) 恢复 web+AI ##########"
cd /root/rk/web || exit 1
AI=1 AI_SRC=ai nohup bash ./start_webstream.sh /dev/video22 9012 > /tmp/web_ai.log 2>&1 &
sleep 10
netstat -lntp 2>/dev/null | grep 9012 && echo "  已恢复"
