set -u
echo "== 停服务, 独占 video22 =="
systemctl stop mipi-webstream
sleep 1
dmesg -C
echo "== 设为 JPEG 输出 (0x0B=1) =="
i2cset -y 9 0x40 0x0B 1
i2cget -y 9 0x40 0x0B
sleep 2
v4l2-ctl -d /dev/video22 --set-fmt-video=width=1920,height=1080,pixelformat=NV16
echo "== 抓 8 帧 =="
timeout 20 v4l2-ctl -d /dev/video22 --stream-mmap --stream-count=8 --stream-to=/tmp/jp.raw 2>&1 | tail -5
echo "== 文件 =="
ls -l /tmp/jp.raw 2>/dev/null || echo "(无文件)"
echo "== dmesg =="
dmesg | tail -20
python3 - <<'PY'
import os, re
p = '/tmp/jp.raw'
if not os.path.exists(p):
    print("no file"); raise SystemExit
d = open(p, 'rb').read()
print("size", len(d), "=%.2f 帧(4.1MB)" % (len(d)/4147200.0))
soi = [m.start() for m in re.finditer(b'\xff\xd8\xff', d)]
eoi = [m.start() for m in re.finditer(b'\xff\xd9', d)]
print("FFD8FF 次数", len(soi), "前几个偏移", soi[:5])
print("FFD9  次数", len(eoi), "前几个偏移", eoi[:5])
nz = sum(1 for b in d[:4194304] if b)
print("第 0 帧非零字节占比 %.2f%%" % (100.0*nz/max(1,min(len(d),4194304))))
if soi:
    s = soi[0]
    print("首帧 JPEG 头部:", d[s:s+24].hex())
PY
echo "== 恢复 NV16 通路 =="
i2cset -y 9 0x40 0x0B 0
sleep 1
systemctl start mipi-webstream
sleep 2
systemctl is-active mipi-webstream
