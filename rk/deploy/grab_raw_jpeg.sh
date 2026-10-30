#!/bin/sh
# 抓 FPGA 原始 CSI-2 buffer, 提取其中 JPEG, 做分区像素统计。
# 目的: 判断绿屏是 FPGA 编码器输入就绿, 还是 RK 侧解析问题。

DEV=/dev/video22
OUT=/tmp/raw_grab.bin
PY=/opt/miniforge3/envs/mlk-ov/bin/python
N=${1:-5}

echo "== 停 web 服务 =="
systemctl stop mipi-webstream
sleep 1.5

echo "== 抓 $N 帧原始 buffer =="
v4l2-ctl -d $DEV --set-fmt-video=width=1920,height=1080,pixelformat=NV16 \
    --stream-mmap --stream-count=$N --stream-to=$OUT 2>&1 | tail -4
ls -la $OUT 2>/dev/null

echo "== 恢复 web 服务 =="
systemctl start mipi-webstream

echo
echo "== 提取 JPEG =="
$PY - "$OUT" <<'PYEOF'
import sys, os
raw = open(sys.argv[1], "rb").read()
print("buffer size:", len(raw))
print("first 16 bytes:", raw[:16].hex())
print("FFD8 at 0:", raw[0] == 0xFF and raw[1] == 0xD8)

offs, i = [], 0
while True:
    i = raw.find(b"\xff\xd8\xff", i)
    if i < 0:
        break
    offs.append(i)
    i += 2
print("FFD8 count:", len(offs), "first offsets:", offs[:10])

for k, off in enumerate(offs[:6]):
    e = raw.find(b"\xff\xd9", off + 2)
    if e < 0:
        print("  #%d off=%d  NO EOI (truncated)" % (k, off))
        continue
    jpg = raw[off:e + 2]
    p = "/tmp/fpga_%d.jpg" % k
    open(p, "wb").write(jpg)
    print("  #%d off=%d len=%d -> %s" % (k, off, len(jpg), p))
PYEOF

echo
echo "== 分区像素统计 =="
$PY - <<'PYEOF'
import glob
try:
    from PIL import Image
except Exception as e:
    print("no PIL:", e); raise SystemExit(0)
import numpy as np

for f in sorted(glob.glob("/tmp/fpga_*.jpg")):
    try:
        im = Image.open(f); im.load()
        a = np.asarray(im.convert("RGB")).astype(np.float32)
        h, w, _ = a.shape
        print("%s: %dx%d mode=%s" % (f, w, h, im.mode))
        zones = {
            "x0-25%  y0-25%": (0, h // 4, 0, w // 4),
            "x25-50% y0-25%": (0, h // 4, w // 4, w // 2),
            "x50-75% y0-25%": (0, h // 4, w // 2, 3 * w // 4),
            "x75-100% y0-25%": (0, h // 4, 3 * w // 4, w),
            "x0-25%  y75-100%": (3 * h // 4, h, 0, w // 4),
            "x25-50% y75-100%": (3 * h // 4, h, w // 4, w // 2),
            "x50-75% y75-100%": (3 * h // 4, h, w // 2, 3 * w // 4),
            "x75-100% y75-100%": (3 * h // 4, h, 3 * w // 4, w),
        }
        for name, (y0, y1, x0, x1) in zones.items():
            b = a[y0:y1, x0:x1]
            print("   %s: R=%6.1f G=%6.1f B=%6.1f  std=%5.1f"
                  % (name, b[..., 0].mean(), b[..., 1].mean(),
                     b[..., 2].mean(), b.std()))
    except Exception as ex:
        print("%s: ERROR %s" % (f, ex))
PYEOF
