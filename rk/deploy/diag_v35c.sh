#!/bin/sh
# V35c 烧录后客观遥测: 只看可测量的数字, 不判断画面好坏
echo "########## 0) 设备在线? ##########"
uname -a
echo -n "FPGA 版本: "
python3 /root/rk/deploy/fpga_cfg.py get 0xA9 2>&1 | tail -1

echo ""
echo "########## 1) FPGA 帧计数两次采样 (间隔 10s) ##########"
FC1=$(python3 /root/rk/deploy/fpga_cfg.py get 0xB8 2>&1 | tail -1)
echo "  采样1 raw: $FC1"
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -iE "frame|帧计数" 
sleep 10
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -iE "frame|帧计数"

echo ""
echo "########## 2) dmesg: CSI / rkcif / dphy 报错 ##########"
dmesg 2>/dev/null | grep -iE "rkcif|mipi3|csi2|dphy3|milianke|mipi-lvds" | tail -25

echo ""
echo "########## 3) 当前 video 节点与格式 ##########"
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | head -6
echo "--- 支持的分辨率 ---"
v4l2-ctl -d /dev/video22 --list-frame-sizes 2>&1 | head -8

echo ""
echo "########## 4) 谁在跑 / 端口 ##########"
ps aux 2>/dev/null | grep -E 'webstream|ai_webstream' | grep -v grep | head -5
netstat -lntp 2>/dev/null | grep -E "9012|9013"

echo ""
echo "########## 5) 网页接口自测 (只看 HTTP 码和字节数) ##########"
for u in / /snapshot.jpg /status /api/status /stats; do
  code=$(curl -s -o /tmp/_c.bin -w "%{http_code}" -m 5 "http://127.0.0.1:9012$u" 2>/dev/null)
  sz=$(wc -c < /tmp/_c.bin 2>/dev/null)
  echo "  $u -> HTTP $code, ${sz} bytes"
done

echo ""
echo "########## 6) 最近 30 行 web 日志 ##########"
tail -30 /tmp/web_ai.log 2>/dev/null || tail -30 /tmp/web.log 2>/dev/null || echo "  (无日志)"

echo ""
echo "########## 完成 ##########"
