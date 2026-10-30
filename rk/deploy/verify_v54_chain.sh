#!/bin/sh
# verify_v54_chain.sh —— V54 (0x5400) 全链验收: FPGA 双路->拼接->预处理->JPEG->CSI-2->RK
#
# 用法(板端):  sh /root/rk/deploy/verify_v54_chain.sh
# 判据(全部满足才算通):
#   1) CFG_VER == 0x5400
#   2) 0xA0~0xA2 (上一帧字节数) 非 0 且每次读在变
#   3) 抓到的帧以 FF D8 开头、含 FF D9, 且能解出 3840x1080
#   4) dmesg 里没有 MIPI_CSI2 ERR (ecc/crc)
D=/root/rk/deploy
CFG="python3 $D/fpga_cfg.py"
DEV=${DEV:-/dev/video22}

echo "########## 0) FPGA 版本与诊断 ##########"
LO=$($CFG get 0xA9 2>&1 | tail -1)
HI=$($CFG get 0xAA 2>&1 | tail -1)
echo "  CFG_VER  = 0x${HI#0x}${LO#0x}   (期望 0x5400; 注意 A9=低字节, AA=高字节)"
echo -n "  0x0B (bit0=jpg_tx bit2=jpg_pad) = "; $CFG get 0x0B 2>&1 | tail -1
for i in 1 2 3; do
    B0=$($CFG get 0xA0 2>&1 | tail -1)
    B1=$($CFG get 0xA1 2>&1 | tail -1)
    B2=$($CFG get 0xA2 2>&1 | tail -1)
    A7=$($CFG get 0xA7 2>&1 | tail -1)
    E4=$($CFG get 0xE4 2>&1 | tail -1)
    E5=$($CFG get 0xE5 2>&1 | tail -1)
    A3=$($CFG get 0xA3 2>&1 | tail -1)
    echo "  t=$i  prev_frame_bytes=$B2$B1$B0  bridge_stall=$A7  lvl_lo=$E4 rcnt=$E5  acc_lo=$A3"
    sleep 1
done

echo ""
echo "########## 1) 停 web (独占 $DEV) ##########"
pkill -f mipi_webstream.py 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 2

echo ""
echo "########## 2) RK 侧按拼接分辨率接收 (默认 3840x1080) ##########"
# 拼接后 FPGA 输出 3840x1080 (左半 cam1 + 右半 cam0), 不是单目的 1920x1080,
# 也不是 4K 的 3840x2160。想让 rkcif 收得下必须三处 (sensor/dphy/csi2) 都改。
W=${W:-3840}
H=${H:-1080}
MED=$(ls /dev/media* 2>/dev/null | head -1)
for e in "m02_back_FPGA-MIPI 9-001a" "rockchip-csi2-dphy3" "rockchip-mipi-csi2"; do
    media-ctl -d $MED --set-v4l2 "\"$e\":0[fmt:YUYV8_2X8/${W}x${H}]" >/dev/null 2>&1 \
        && echo "  $e:0 -> ${W}x${H} ok" || echo "  $e:0 FAIL (名字/设备号可能不同)"
done
v4l2-ctl -d $DEV --set-fmt-video=width=$W,height=$H,pixelformat=YUYV >/dev/null 2>&1
v4l2-ctl -d $DEV --get-fmt-video 2>&1 | head -4
rm -f /tmp/v54.raw
timeout 20 v4l2-ctl -d $DEV --stream-mmap=4 --stream-count=2 --stream-to=/tmp/v54.raw 2>&1 | tail -5
SZ=$(stat -c %s /tmp/v54.raw 2>/dev/null || echo 0)
echo "  >>>>> 抓到 $SZ 字节 <<<<<"

echo ""
echo "########## 3) 从缓冲里扫 FFD8..FFD9 ##########"
python3 - <<'PY'
import sys
try:
    b = open('/tmp/v54.raw','rb').read()
except Exception as e:
    print("  读取失败:", e); sys.exit(1)
n = b.count(b'\xff\xd8\xff')
print("  缓冲区 %d 字节, SOI(FFD8FF) 出现 %d 次" % (len(b), n))
ok = 0
off = 0
for k in range(min(n, 4)):
    s = b.find(b'\xff\xd8', off)
    if s < 0: break
    e = b.find(b'\xff\xd9', s+2)
    if e < 0:
        print("  #%d @%d: 没找到 EOI (帧可能被截断)" % (k, s)); off = s+2; continue
    seg = b[s:e+2]
    print("  #%d @%6d  len=%7d  尾部=%s" % (k, s, len(seg), seg[-4:].hex(' ')))
    open('/tmp/frame%d.jpg' % k, 'wb').write(seg)
    ok += 1
    off = e+2
print("  已导出 %d 个 JPEG 到 /tmp/frame*.jpg" % ok)
sys.exit(0 if ok else 1)
PY

echo ""
echo "########## 4) dmesg (看有没有 MIPI ECC/CRC) ##########"
dmesg 2>&1 | grep -iE "rkcif|mipi3|dphy3|csi2.*err|ecc|crc" | tail -12
echo "  (若刷 ECC/CRC => 整板 reboot, 寄存器层救不回来)"

echo ""
echo "########## 5) 结论 ##########"
echo "  - 0xA0~A2 恒 0  => 一帧都没编完过"
echo "  - bridge_stall 在涨 => 看门狗在响"
echo "  - /tmp/frame0.jpg 可用 'python3 -c \"from PIL import Image;print(Image.open(\\\"/tmp/frame0.jpg\\\").size)\"' 验证"
