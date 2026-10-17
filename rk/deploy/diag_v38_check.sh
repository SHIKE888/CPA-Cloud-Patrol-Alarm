#!/bin/sh
F=/root/rk/deploy/fpga_cfg.py
g() { python3 $F get $1 2>&1 | tail -1 | sed 's/.*(//;s/).*//'; }
rd_csi()  { local a=$(g 0xB8) b=$(g 0xB9) c=$(g 0xBA) d=$(g 0xBB); echo $((d*16777216 + c*65536 + b*256 + a)); }
rd_corr() { local a=$(g 0xD0) b=$(g 0xD1); echo $((b*256 + a)); }
rd_lg()   { local a=$(g 0xD4) b=$(g 0xD5); echo $((b*256 + a)); }

echo -n "VER = 0x"; printf '%02X%02X\n' $(g 0xAA) $(g 0xA9)
echo "(V38 应为 0x3801)"
echo -n "RES_MODE = "; python3 $F get 0xE0 2>&1 | tail -1

echo ""
echo "=== 确保推流在跑 (否则 mipi-en 拉低, 传感器不出帧) ==="
/usr/local/bin/start.sh status 2>&1 | grep -E "web |监听|RES_MODE" | head -4
if ! netstat -lnt 2>/dev/null | grep -q ":9012 "; then
  echo "  9012 未监听, 启动 4K 推流..."
  /usr/local/bin/start.sh 4k > /tmp/_rv.log 2>&1
  sleep 12
  netstat -lnt 2>/dev/null | grep ":9012 " && echo "  已启动" || echo "  启动失败"
fi

echo ""
echo "=== 采计 8 秒 ==="
echo "行组数 = $(rd_lg)   (4K 全像素应 966; binning 486)"
c1=$(rd_csi); k1=$(rd_corr)
sleep 8
c2=$(rd_csi); k2=$(rd_corr)
dc=$((c2-c1)); dk=$((k2-k1)); [ $dk -lt 0 ] && dk=$((dk+65536))
echo "CSI-2 帧首计数: $c1 -> $c2   Δ$dc/8s = $(awk "BEGIN{printf \"%.2f\",$dc/8}") fps   <- 传感器真实帧率"
echo "裁剪输出帧计数: $k1 -> $k2   Δ$dk/8s = $(awk "BEGIN{printf \"%.2f\",$dk/8}") fps"
echo "行组数(再读) = $(rd_lg)"
