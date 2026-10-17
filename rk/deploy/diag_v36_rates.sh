#!/bin/sh
# V36: 一次读数同时拿到【传感器真实帧率】和【FPGA 输出帧率】
#   0xB8..0xBB = CSI-2 FS 短包计数  -> 传感器真实帧率
#   0xD0/0xD1  = 裁剪模块输出帧计数(低16位, 会回转)
#   v4l2-ctl   = rkcif 收到的帧率   -> FPGA 实际吐出的帧率
F=/root/rk/deploy/fpga_cfg.py
DEV=/dev/video22

g() { python3 $F get $1 2>&1 | tail -1 | sed 's/.*(//;s/).*//'; }

rd_csi() {  # 32 位 CSI FS 计数
  local a=$(g 0xB8) b=$(g 0xB9) c=$(g 0xBA) d=$(g 0xBB)
  echo $((d*16777216 + c*65536 + b*256 + a))
}
rd_corr() { # 16 位裁剪帧计数
  local a=$(g 0xD0) b=$(g 0xD1)
  echo $((b*256 + a))
}

echo "########## 0) 版本 ##########"
l=$(g 0xA9); h=$(g 0xAA)
echo "  VER = 0x$(printf '%02X' $h)$(printf '%02X' $l)"
if [ "$h" -ne 0x36 ]; then echo "  !! 不是 V36 的 bit, 先重新烧录"; exit 0; fi

echo ""
echo "########## 1) 停 web ##########"
pkill -f 'mipi_webstream\.py' 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 3

echo ""
echo "########## 2) 同时采计 10 秒 ##########"
c1=$(rd_csi);  k1=$(rd_corr)
T0=$(date +%s%N)
sleep 10
T1=$(date +%s%N)
c2=$(rd_csi);  k2=$(rd_corr)
DT=$(awk "BEGIN{printf \"%.3f\", ($T1-$T0)/1000000000}")
DC=$((c2 - c1)); DK=$((k2 - k1))
if [ "$DK" -lt 0 ]; then DK=$((DK + 65536)); fi
echo "  经过 ${DT}s"
echo "  CSI-2 FS 计数 : $c1 -> $c2  (Δ$DC)  => 传感器真实帧率 = $(awk "BEGIN{printf \"%.2f\", $DC/$DT}") fps"
echo "  裁剪输出帧计数: $k1 -> $k2  (Δ$DK)  => 裁剪后帧率      = $(awk "BEGIN{printf \"%.2f\", $DK/$DT}") fps"

echo ""
echo "########## 3) rkcif 实际收到的帧率 ##########"
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
timeout 40 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=60 --stream-to=/dev/null > /tmp/f.txt 2>&1
V=$(grep -oE '[0-9]+\.[0-9]+ fps' /tmp/f.txt 2>/dev/null | tail -1)
echo "  => rkcif 收到 = $V"

echo ""
echo "########## 4) 判读 ##########"
echo "  若 传感器 12.5 / 裁剪 12.5 / rkcif 12.5  => 传感器本身只给 12.5"
echo "  若 传感器 25.0 / 裁剪 25.0 / rkcif 12.5  => FPGA 后级把帧丢了一半"
echo "  若 传感器 25.0 / 裁剪 12.5 / rkcif 12.5  => ui_image_correction 丢帧"
echo "  若 传感器 25.0 / 裁剪 0    / rkcif 12.5  => 裁剪模块的 tuser/tlast 不通"

echo ""
echo "########## 5) 恢复推流 ##########"
/usr/local/bin/start.sh 4k > /tmp/_rA.log 2>&1
grep -E "已启动|RES_MODE" /tmp/_rA.log | head -4
echo ""
echo "########## 完成 ##########"
