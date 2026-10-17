#!/bin/sh
# V35d 烧录后: 只看 4K 实测帧率 + 链路是否干净
F=/root/rk/deploy/fpga_cfg.py
DEV=/dev/video22

echo "########## A) FPGA 状态 ##########"
echo -n "  RES_MODE 0xE0 = "; python3 $F get 0xE0 2>&1 | tail -1
a=$(python3 $F get 0xD4 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
b=$(python3 $F get 0xD5 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
echo "  行组数 0xD5/0xD4 = 0x$b$a   (4K 全像素应 966 = 0x3C6)"
echo -n "  ROI 0xC8 = "; python3 $F get 0xC8 2>&1 | tail -1

echo ""
echo "########## B) 停 web ##########"
pkill -f 'mipi_webstream\.py' 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 3
dmesg -c > /dev/null 2>&1

echo ""
echo "########## C) 4K 实测帧率 (40 帧) ##########"
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
T0=$(date +%s%N)
timeout 30 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=40 --stream-to=/dev/null > /tmp/f1.txt 2>&1
RC=$?
T1=$(date +%s%N)
MS=$(( (T1-T0)/1000000 ))
echo "  rc=$RC  40帧 墙钟 ${MS}ms  (墙钟含进程启动开销, 看下面 v4l2 自报更准)"
echo "  v4l2-ctl 自报的逐行帧率:"
grep -E 'fps' /tmp/f1.txt 2>/dev/null | sed 's/^/    /'
V=$(grep -oE '[0-9]+\.[0-9]+ fps' /tmp/f1.txt 2>/dev/null | tail -1)
echo "  ==> 最终自报 = $V"

echo ""
echo "########## D) 再测一次 (60 帧) 确认稳定 ##########"
T0=$(date +%s%N)
timeout 30 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=60 --stream-to=/dev/null > /tmp/f2.txt 2>&1
RC=$?
T1=$(date +%s%N)
MS=$(( (T1-T0)/1000000 ))
V2=$(grep -oE '[0-9]+\.[0-9]+ fps' /tmp/f2.txt 2>/dev/null | tail -1)
echo "  rc=$RC  60帧 墙钟 ${MS}ms  => 自报 $V2"

echo ""
echo "########## E) 链路错误 (本次清空后新的) ##########"
echo -n "  ECC 条数 : "; dmesg 2>/dev/null | grep -c "ecc"
echo -n "  CRC 条数 : "; dmesg 2>/dev/null | grep -c "crc"
echo -n "  vblank 警告: "; dmesg 2>/dev/null | grep -c "vblank"
dmesg 2>/dev/null | grep -iE "ERR|ecc|crc|vblank|size|timeout" | tail -12

echo ""
echo "########## F) 恢复推流 ##########"
/usr/local/bin/start.sh 4k > /tmp/_r5.log 2>&1
grep -E "已启动|RES_MODE|监听" /tmp/_r5.log | head -5
sleep 8
echo -n "  /api/ai : "
curl -s -m 6 "http://127.0.0.1:9012/api/ai" 2>/dev/null | head -c 160
echo ""
echo ""
echo "########## 完成 ##########"
