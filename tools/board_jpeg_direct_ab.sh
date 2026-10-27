#!/bin/bash
#=============================================================================
#  烧 0x470A 之后的自动验收: 依次测 4 种配置, 每种都记录 fps / 直通 / 延时
#    A) 0x0B=0x00  原 NV16 通路        (基线, 应回到 ~55fps)
#    B) 0x0B=0x05  JPEG + DT=0x1E + 补满整帧   (默认方案)
#    C) 0x0B=0x01  JPEG + DT=0x1E + 短帧       (省带宽, 未知收端行为)
#    D) 0x0B=0x07  JPEG + DT=0x18 + 补满整帧   (预期被 rkcif 拒收)
#  用法: bash /tmp/jd.sh  [A|B|C|D]
#=============================================================================
set -u
DEV=/dev/video22
API=http://127.0.0.1:9012/api/sys
MODE=${1:-ALL}

ver() {
    a=$(i2cget -y 9 0x40 0xA9); b=$(i2cget -y 9 0x40 0xAA)
    echo "CFG_VER = ${b#0x}${a#0x}   (期望 47 0A)"
}

settle() {   # 停服务 -> 设备空闲 -> 等 1s
    systemctl stop mipi-webstream >/dev/null 2>&1
    sleep 2
}

svc() {
    systemctl start mipi-webstream >/dev/null 2>&1
    sleep 6
}

# 用 cv2 直抓 60 帧测真实 fps (v4l2-ctl 的 dropped buffers 会误导)
capfps() {
    /opt/miniforge3/envs/mlk-ov/bin/python /tmp/capfps.py 2>&1 | grep -E '间隔|帧太少'
}

# 抓一帧看帧首 8 字节 + 是不是 JPEG
rawprobe() {
    timeout 12 v4l2-ctl -d $DEV --stream-mmap --stream-count=3 \
            --stream-to=/tmp/p.raw >/dev/null 2>&1
    python3 - <<'PY'
import os
p = '/tmp/p.raw'
n = os.path.getsize(p) if os.path.exists(p) else 0
print("抓到的字节数 %d (=%.2f 帧)" % (n, n / 4147200.0))
if n >= 8:
    d = open(p, 'rb').read()
    soi = d.find(b'\xff\xd8')
    eoi = d.find(b'\xff\xd9')
    print("  头 8 字节 %s   SOI@%d  EOI@%d" % (d[:8].hex(), soi, eoi))
    if soi == 0 and eoi > 1024:
        print("  => JPEG %.1f KB" % ((eoi + 2) / 1024.0))
PY
    rm -f /tmp/p.raw
}

apsys() {
    curl -s -m 6 $API > /tmp/ap.json 2>/dev/null
    /usr/bin/python3 - <<'PY'
import json
try:
    d = json.load(open('/tmp/ap.json'))
except Exception:
    print("  /api/sys 无响应"); raise SystemExit
m = d.get('mipi', {})
print("  fps=%s  capture_to_ready=%sms  直通=%s  压缩比=%s  单帧=%sB"
      % (d.get('fps'), (d.get('latency_ms') or {}).get('capture_to_ready'),
         m.get('jpeg_direct'), m.get('ratio'), m.get('jpeg_bytes')))
print("  queues=%s" % (d.get('queues'),))
PY
}

run_case() {
    local name=$1 val=$2
    echo
    echo "================ $name  (0x0B=$val) ================"
    settle
    i2cset -y 9 0x40 0x0B "$val"
    echo "0x0B 回读: $(i2cget -y 9 0x40 0x0B)"
    dmesg -C
    capfps
    rawprobe
    echo "-- dmesg (CSI 错误) --"
    dmesg | grep -iE 'MIPI_CSI2|rkcif|error' | head -6
    svc
    apsys
}

ver
case "$MODE" in
  A) run_case "A 原 NV16"      0x00 ;;
  B) run_case "B JPEG+DT1E+补满" 0x05 ;;
  C) run_case "C JPEG+DT1E+短帧" 0x01 ;;
  D) run_case "D JPEG+DT18"    0x07 ;;
  ALL)
    run_case "A 原 NV16"        0x00
    run_case "B JPEG+DT1E+补满"  0x05
    run_case "C JPEG+DT1E+短帧"  0x01
    run_case "D JPEG+DT18"      0x07
    echo
    echo "== 回到默认: 原 NV16 通路 =="
    settle
    i2cset -y 9 0x40 0x0B 0x00
    svc
    apsys
    ;;
esac
