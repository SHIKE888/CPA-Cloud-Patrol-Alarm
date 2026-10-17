#!/bin/sh
# 测刚烧的 V35d (VMAX=2788) 是否把 4K 拉到 25fps
# 注: 这一版还没有 CFG_VER, 0xA9/0xAA 会读回旧值, 不做版本门禁
F=/root/rk/deploy/fpga_cfg.py
DEV=/dev/video22

echo "########## 0) 状态 ##########"
l=$(python3 $F get 0xA9 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
h=$(python3 $F get 0xAA 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
echo "  VER 0xAA:0xA9 = 0x$h$l  (V35e 起才会是 0x3504; 本版应为旧值)"
echo -n "  RES_MODE 0xE0 = "; python3 $F get 0xE0 2>&1 | tail -1
a=$(python3 $F get 0xD4 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
b=$(python3 $F get 0xD5 2>&1 | tail -1 | sed 's/.*= 0x//;s/ .*//')
echo "  行组数 = 0x$b$a   (4K 全像素应 966 = 0x3C6)"
echo -n "  CAM_ID 0xD3 = "; python3 $F get 0xD3 2>&1 | tail -1

echo ""
echo "########## 1) 停 web ##########"
pkill -f 'mipi_webstream\.py' 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 3
dmesg -c > /dev/null 2>&1

echo ""
echo "########## 2) 4K 实测帧率 (三组, 看稳定性) ##########"
v4l2-ctl -d $DEV --set-fmt-video=width=3840,height=2160,pixelformat=NV16 >/dev/null 2>&1
for n in 40 60 100; do
  T0=$(date +%s%N)
  timeout 60 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=$n --stream-to=/dev/null > /tmp/f.txt 2>&1
  RC=$?
  T1=$(date +%s%N)
  MS=$(( (T1-T0)/1000000 ))
  V=$(grep -oE '[0-9]+\.[0-9]+ fps' /tmp/f.txt 2>/dev/null | tail -1)
  echo "  ${n}帧 rc=$RC 墙钟${MS}ms => $V"
done

echo ""
echo "  ---- 判读 ----"
echo "  ≈24.99 => VMAX 生效, 帧率正确"
echo "  ≈12.5  => 传感器把帧时间钳在 80ms 下限, VMAX 拉不动"

echo ""
echo "########## 3) 链路错误 (本次) ##########"
echo -n "  ECC: "; dmesg 2>/dev/null | grep -c "ecc"
echo -n "  CRC: "; dmesg 2>/dev/null | grep -c "crc"
dmesg 2>/dev/null | grep -iE "ERR|ecc|crc|timeout|size" | tail -8

echo ""
echo "########## 4) 恢复推流 ##########"
/usr/local/bin/start.sh 4k > /tmp/_r8.log 2>&1
grep -E "已启动|RES_MODE" /tmp/_r8.log | head -4
echo ""
echo "########## 完成 ##########"
