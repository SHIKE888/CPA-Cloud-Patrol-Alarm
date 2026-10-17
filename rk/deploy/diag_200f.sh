#!/bin/sh
F=/root/rk/deploy/fpga_cfg.py
DEV=/dev/video22
g() { python3 $F get $1 2>&1 | tail -1 | sed 's/.*(//;s/).*//'; }
rd_csi() { local a=$(g 0xB8) b=$(g 0xB9) c=$(g 0xBA) d=$(g 0xBB); echo $((d*16777216 + c*65536 + b*256 + a)); }

pkill -f 'mipi_webstream\.py' 2>/dev/null
sleep 3

echo "=== 传感器 (6s) ==="
c1=$(rd_csi); sleep 6; c2=$(rd_csi)
echo "  $(awk "BEGIN{printf \"%.3f\",($c2-$c1)/6}") fps"

echo ""
echo "=== rkcif 200 帧 (降低启动开销影响) ==="
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
T0=$(date +%s%N)
timeout 90 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=200 --stream-to=/dev/null > /tmp/q2.txt 2>&1
RC=$?
T1=$(date +%s%N)
MS=$(( (T1-T0)/1000000 ))
echo "  rc=$RC 墙钟 ${MS}ms"
echo -n "  v4l2 自报: "; grep -oE '[0-9]+\.[0-9]+ fps' /tmp/q2.txt 2>/dev/null | tail -1
echo "  墙钟折算: $(awk -v m=$MS 'BEGIN{printf "%.2f", 200000/m}') fps"

echo ""
echo "=== 再测一次传感器, 确认测量期间稳定 ==="
c1=$(rd_csi); sleep 6; c2=$(rd_csi)
echo "  $(awk "BEGIN{printf \"%.3f\",($c2-$c1)/6}") fps"

echo ""
echo "=== 恢复推流 ==="
/usr/local/bin/start.sh 4k > /tmp/_ry.log 2>&1
sleep 10
netstat -lnt 2>/dev/null | grep -q ":9012 " && echo "  已恢复" || echo "  !! 恢复失败"
