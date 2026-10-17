#!/bin/sh
# V38e 综合验证: 版本 / 传感器帧率 / rkcif 帧率 / 行组数 / 链路错误
F=/root/rk/deploy/fpga_cfg.py
DEV=/dev/video22
g() { python3 $F get $1 2>&1 | tail -1 | sed 's/.*(//;s/).*//'; }
rd_csi()  { local a=$(g 0xB8) b=$(g 0xB9) c=$(g 0xBA) d=$(g 0xBB); echo $((d*16777216 + c*65536 + b*256 + a)); }
rd_corr() { local a=$(g 0xD0) b=$(g 0xD1); echo $((b*256 + a)); }
rd_lg()   { local a=$(g 0xD4) b=$(g 0xD5); echo $((b*256 + a)); }

echo "########## 1) 版本 ##########"
echo -n "  VER = 0x"; printf '%02X%02X\n' $(g 0xAA) $(g 0xA9)
echo "  (期望 0x3805)"
echo -n "  RES_MODE = "; python3 $F get 0xE0 2>&1 | tail -1

echo ""
echo "########## 2) 停 web (测量用, 马上恢复) ##########"
pkill -f 'mipi_webstream\.py' 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 3
dmesg -c > /dev/null 2>&1

echo ""
echo "########## 3) 传感器帧率 (CSI-FS) + 裁剪帧率 ##########"
echo "  行组数 = $(rd_lg)   (4K 全像素应 966)"
for i in 1 2; do
  c1=$(rd_csi); k1=$(rd_corr)
  sleep 6
  c2=$(rd_csi); k2=$(rd_corr)
  dc=$((c2-c1)); dk=$((k2-k1)); [ $dk -lt 0 ] && dk=$((dk+65536))
  echo "  第$i次: 传感器 $(awk "BEGIN{printf \"%.2f\",$dc/6}") fps   裁剪 $(awk "BEGIN{printf \"%.2f\",$dk/6}") fps"
done

echo ""
echo "########## 4) rkcif 实收帧率 (墙钟计算) ##########"
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
done

echo ""
echo "########## 5) 链路错误 (本次测量期间) ##########"
echo -n "  ECC: "; dmesg 2>/dev/null | grep -c "ecc"
echo -n "  CRC: "; dmesg 2>/dev/null | grep -c "crc"
echo -n "  vblank 警告: "; dmesg 2>/dev/null | grep -c "vblank"
dmesg 2>/dev/null | grep -iE "ERR|ecc|crc|vblank|size|timeout|overflow" | tail -8

echo ""
echo "########## 6) 恢复推流 ##########"
/usr/local/bin/start.sh 4k > /tmp/_rx.log 2>&1
sleep 10
netstat -lnt 2>/dev/null | grep ":9012 " >/dev/null && echo "  已恢复" || echo "  !! 恢复失败"
echo ""
echo "########## 完成 ##########"
