#!/bin/sh
# 切回 1080p 并把 Web(9012) + AI(9013) 一起拉起来
echo "########## 1) 切 1080p: 写 RES_MODE(0xE0)=0 ##########"
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 0 2>&1
sleep 3
echo -n "  0xE0  = "; python3 /root/rk/deploy/fpga_cfg.py get 0xE0 2>&1 | tail -1
echo -n "  0xD4  = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD4 2>&1 | tail -1
echo -n "  0xD5  = "; python3 /root/rk/deploy/fpga_cfg.py get 0xD5 2>&1 | tail -1
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -E "帧计数"

echo ""
echo "########## 2) 帧率测量 (1080p60 期望 ~60) ##########"
A=$(python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -o '帧计数 = [0-9]*' | tr -dc '0-9')
sleep 5
B=$(python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -o '帧计数 = [0-9]*' | tr -dc '0-9')
echo "  A=$A B=$B delta=$((B-A)) 5s  => $(( (B-A)/5 )) fps"

echo ""
echo "########## 3) 起 Web 推流 (端口 9012) ##########"
pkill -f mipi_webstream.py 2>/dev/null && echo "  杀掉旧 web" || echo "  无旧 web"
sleep 1
cd /root/rk/web || exit 1
nohup bash ./start_webstream.sh /dev/video22 9012 > /tmp/web_start.log 2>&1 &
sleep 10
echo "--- /tmp/web_start.log 尾部 ---"
tail -n 22 /tmp/web_start.log
echo "--- 端口监听 ---"
netstat -lntp 2>/dev/null | grep -E "9012|9013" || ss -lntp 2>/dev/null | grep -E "9012|9013"

echo ""
echo "########## 4) 起 AI 标注 (端口 9013, 源=http://127.0.0.1:9012/stream) ##########"
ls -l /root/rk/ai/models/ 2>&1 | head -8
cd /root/rk/ai || exit 1
SRC=http://127.0.0.1:9012/stream PORT=9013 bash board/start_ai.sh 2>&1 | tail -35
sleep 3
echo "--- 端口监听 ---"
netstat -lntp 2>/dev/null | grep -E "9012|9013" || ss -lntp 2>/dev/null | grep -E "9012|9013"
echo ""
echo "本机 IP: $(hostname -I | awk '{print $1}')"
echo "  Web 画面: http://$(hostname -I | awk '{print $1}'):9012/"
echo "  AI  标注: http://$(hostname -I | awk '{print $1}'):9013/"
