#!/bin/sh
# 判定: FPGA 到底吐了多少帧给 RK
F=/root/rk/deploy/fpga_cfg.py
DEV=/dev/video22
g() { python3 $F get $1 2>&1 | tail -1 | sed 's/.*(//;s/).*//'; }
rd_csi()  { local a=$(g 0xB8) b=$(g 0xB9) c=$(g 0xBA) d=$(g 0xBB); echo $((d*16777216 + c*65536 + b*256 + a)); }

echo "=== 停 web (只为测量, 测完恢复) ==="
pkill -f 'mipi_webstream\.py' 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 3

echo ""
echo "=== 传感器侧 (CSI-FS 计数) ==="
c1=$(rd_csi); sleep 6; c2=$(rd_csi)
echo "  Δ$((c2-c1))/6s = $(awk "BEGIN{printf \"%.2f\",($c2-$c1)/6}") fps"

echo ""
echo "=== rkcif 侧 (v4l2-ctl 实收, 墙钟计算) ==="
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
for n in 40 80; do
  T0=$(date +%s%N)
  timeout 60 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=$n --stream-to=/dev/null > /tmp/q.txt 2>&1
  RC=$?
  T1=$(date +%s%N)
  MS=$(( (T1-T0)/1000000 ))
  if [ "$RC" = "0" ]; then
    echo "  ${n}帧 墙钟 ${MS}ms => $(awk "BEGIN{printf \"%.2f\", $n*1000/$MS}") fps"
  else
    echo "  ${n}帧 rc=$RC (超时/失败) 墙钟 ${MS}ms"
  fi
  grep -oE '[0-9]+\.[0-9]+ fps' /tmp/q.txt 2>/dev/null | tail -1 | sed 's/^/      v4l2自报 /'
done

echo ""
echo "=== 再测一次传感器侧 (确认测量期间一致) ==="
c1=$(rd_csi); sleep 6; c2=$(rd_csi)
echo "  Δ$((c2-c1))/6s = $(awk "BEGIN{printf \"%.2f\",($c2-$c1)/6}") fps"

echo ""
echo "=== 判读 ==="
echo "  rkcif ≈24.5 => FPGA 没问题, 是网页/JPEG 软件端只能 12.5"
echo "  rkcif ≈12.5 => FPGA 只吐了一半"

echo ""
echo "=== 恢复推流 ==="
/usr/local/bin/start.sh 4k > /tmp/_rw.log 2>&1
sleep 10
netstat -lnt 2>/dev/null | grep ":9012 " >/dev/null && echo "  已恢复 (9012 在监听)" || echo "  !! 恢复失败"
