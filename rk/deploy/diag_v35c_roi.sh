#!/bin/sh
# 判决实验: 12.5fps 到底是传感器慢, 还是输出链路带宽不够
F=/root/rk/deploy/fpga_cfg.py

echo "########## 0) 当前状态 ##########"
echo -n "  RES_MODE 0xE0 = "; python3 $F get 0xE0 2>&1 | tail -1
echo -n "  行组数 0xD4/0xD5 = "; \
  a=$(python3 $F get 0xD4 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//'); \
  b=$(python3 $F get 0xD5 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//'); \
  echo "0x$a 0x$b  (4K 全像素应为 ~966, binning 为 486)"
echo -n "  ROI 0xC8 = "; python3 $F get 0xC8 2>&1 | tail -1

echo ""
echo "########## 1) 停 web ##########"
pkill -f 'mipi_webstream\.py' 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 3

echo ""
echo "########## 2) 基线: ROI=100 测帧率 ##########"
python3 $F set 0xC8 100 > /dev/null 2>&1
T0=$(date +%s%N)
timeout 25 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=25 --stream-to=/dev/null > /tmp/r1.txt 2>&1
RC1=$?
T1=$(date +%s%N)
MS1=$(( (T1-T0)/1000000 ))
echo "  rc=$RC1  25帧 ${MS1}ms"
if [ "$RC1" = "0" ]; then echo "  ==> ROI=100 实测 = $(awk "BEGIN{printf \"%.2f\", 25000/$MS1}") fps"; else echo "  ==> 超时/失败"; fi

echo ""
echo "########## 3) ROI=50 (输出数据量减半) 测帧率 ##########"
python3 $F set 0xC8 50 > /dev/null 2>&1
echo -n "  回读 0xC8 = "; python3 $F get 0xC8 2>&1 | tail -1
sleep 2
T0=$(date +%s%N)
timeout 25 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=50 --stream-to=/dev/null > /tmp/r2.txt 2>&1
RC2=$?
T1=$(date +%s%N)
MS2=$(( (T1-T0)/1000000 ))
echo "  rc=$RC2  50帧 ${MS2}ms"
if [ "$RC2" = "0" ]; then echo "  ==> ROI=50  实测 = $(awk "BEGIN{printf \"%.2f\", 50000/$MS2}") fps"; else echo "  ==> 超时/失败"; fi

echo ""
echo "########## 4) 恢复 ROI=100 ##########"
python3 $F set 0xC8 100 > /dev/null 2>&1
echo -n "  回读 0xC8 = "; python3 $F get 0xC8 2>&1 | tail -1

echo ""
echo "########## 5) 期间 dmesg ##########"
dmesg 2>/dev/null | grep -iE "ERR|ecc|crc|timeout|overflow|size" | tail -10

echo ""
echo "########## 6) 恢复 4K 推流 ##########"
/usr/local/bin/start.sh 4k > /tmp/_r3.log 2>&1
grep -E "已启动|web |FPGA RES_MODE|帧计数" /tmp/_r3.log | head -6
echo ""
echo "########## 完成 ##########"
