#!/bin/bash
# 4K25 不出帧的现场诊断 (不需要重烧 bit)
#
# 要回答的问题:
#   Q1. FPGA 的 RX 还在正常收吗? (FRAME_CNT 速率 + 0xD4/0xD5 行组数)
#   Q2. RK 侧直连能拿到帧吗? (绕开 opencv, 用 v4l2-ctl --stream-mmap)
#   Q3. 内核有没有报 CSI-2/rkcif 错误?
set -u
B=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

regs() {
  python3 - <<'EOF'
import fcntl, time
f = open('/dev/i2c-9', 'r+b', buffering=0)
def rd(r):
    fcntl.ioctl(f, 0x0703, 0x40); f.write(bytes([r])); return f.read(1)[0]
def rdv(r, n=5):
    v = [rd(r) for _ in range(n)]
    return max(set(v), key=v.count)
def cnt():
    return rdv(0xB8) | rdv(0xB9) << 8 | rdv(0xBA) << 16 | rdv(0xBB) << 24
a = cnt(); time.sleep(2); b = cnt()
print("  FRAME_CNT(RX): %d -> %d   = %.1f fps" % (a, b, (b - a) / 2.0))
print("  0xD4 行组[7:0]=%d  0xD5 行组[15:8]=%d  => 每行组数 = %d (x4px = %d px)"
      % (rdv(0xD4), rdv(0xD5), rdv(0xD4) | (rdv(0xD5) << 8),
         (rdv(0xD4) | (rdv(0xD5) << 8)) * 4))
print("  0xE0 RES_MODE=%d" % rdv(0xE0))
f.close()
EOF
}

snap_mean() {
  curl -s -m 25 --output /tmp/d.jpg "$B/snapshot.jpg"
  $PY - <<'EOF'
import cv2
i = cv2.imread('/tmp/d.jpg', cv2.IMREAD_GRAYSCALE)
print("  JPEG %s 亮度=%s" % ((i.shape if i is not None else '无'),
                            ("%.1f" % i.mean()) if i is not None else '-'))
EOF
}

echo "############ 当前 (应为 1080p60 正常工作) ############"
echo "--- FPGA ---"; regs
echo "--- web ---"; curl -s -m 8 $B/api/status | head -c 160; echo
echo "--- 抓帧 ---"; snap_mean

echo
echo "############ 切到 4K25 ############"
pkill -f mipi_webstream.py; sleep 1
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 2 >/dev/null
sleep 1.5
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/3840x2160]' 2>&1 | sed 's/^/  media-ctl: /'
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/3840x2160]' 2>&1 | sed 's/^/  media-ctl: /'
echo "--- FPGA (4K25, 无任何采集者) ---"; regs
echo "--- video22 fmt ---"; v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | grep -E 'Width/Height|Bytes per Line' | sed 's/^/  /'

echo
echo "--- Q2: 绕开 opencv, 直接 v4l2-ctl 抓 3 帧 (10s 超时) ---"
timeout 10 v4l2-ctl -d /dev/video22 --set-fmt-video=width=3840,height=2160,pixelformat=NV16 2>&1 | sed 's/^/  set-fmt: /'
timeout 15 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=3 --stream-to=/tmp/raw4k.bin 2>&1 | sed 's/^/  stream: /'
echo "  抓到的原始数据字节数: $(stat -c %s /tmp/raw4k.bin 2>/dev/null || echo 0)  (一帧应为 $((3840*2160*2)) )"
if [ -s /tmp/raw4k.bin ]; then
  python3 - <<'EOF'
d = open('/tmp/raw4k.bin','rb').read(3840*2160*2)
if len(d) >= 1024:
    import collections
    c = collections.Counter(d[:200000])
    print("  前 200KB 字节分布 top6: %s" % [(hex(k), v) for k, v in c.most_common(6)])
    print("  是否全 0: %s   是否全 0xFF: %s"
          % (set(d[:100000]) == {0}, set(d[:100000]) == {255}))
EOF
fi

echo
echo "--- Q3: 内核日志 (cif/csi/dphy/error) ---"
dmesg | grep -iE 'cif|csi|dphy|error|timeout|overflow' | tail -18 | sed 's/^/  /'

echo
echo "############ 恢复 1080p60 ############"
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 0 >/dev/null
sleep 1.5
media-ctl -d /dev/media2 --set-v4l2 '"m02_back_FPGA-MIPI 9-001a":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
media-ctl -d /dev/media2 --set-v4l2 '"rockchip-mipi-csi2":0[fmt:YUYV8_2X8/1920x1080]' >/dev/null 2>&1
cd /root/rk/web && nohup ./start_webstream.sh > /tmp/webstream.log 2>&1 &
sleep 10
curl -s -m 8 $B/api/status | head -c 160; echo
snap_mean
