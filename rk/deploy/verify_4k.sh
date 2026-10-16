#!/bin/bash
# 4K 验证: 基线 + 切换 + 关键判据
#
# 关键判据: 0xD4/0xD5 = 传感器**实际**每行像素组数(=px/4)
#   1080p (2x2 binning) -> 486 组 (1944 px)
#   4K    (all-pixel)   -> 应该 ~966 组 (3864 px)
# 如果切 4K 后仍是 486, 说明传感器模式没切过去(全表重载/mode 同步的问题)。
B=http://127.0.0.1:9012
PY=/opt/miniforge3/envs/mlk-ov/bin/python

regs() {
  python3 - <<'EOF'
import fcntl, time
f = open('/dev/i2c-9', 'r+b', buffering=0)
def rd(r):
    fcntl.ioctl(f, 0x0703, 0x40); f.write(bytes([r])); return f.read(1)[0]
def rdv(r, n=7):
    v = [rd(r) for _ in range(n)]
    return max(set(v), key=v.count)
def cnt():
    return rdv(0xB8) | rdv(0xB9) << 8 | rdv(0xBA) << 16 | rdv(0xBB) << 24
a = cnt(); time.sleep(2); b = cnt()
g = rdv(0xD4) | (rdv(0xD5) << 8)
print("  RES_MODE(0xE0)=%d   FRAME_CNT(RX)=%d->%d = %.1f fps"
      % (rdv(0xE0), a, b, (b - a) / 2.0))
print("  ★ 0xD4/0xD5 行组数 = %d  (= %d px/行)" % (g, g * 4))
f.close()
EOF
}

shot() {
  curl -s -m 25 --output /tmp/v4.jpg "$B/snapshot.jpg"
  echo "  快照字节数 = $(stat -c %s /tmp/v4.jpg 2>/dev/null || echo 0)"
  $PY - <<'EOF'
import cv2
i = cv2.imread('/tmp/v4.jpg', cv2.IMREAD_GRAYSCALE)
print("  JPEG %s  亮度=%.1f" % ((i.shape if i is not None else '无'),
                              (i.mean() if i is not None else -1)))
EOF
}

echo "############ 1. 基线 (切之前, 应该是 1080p60) ############"
echo "--- FPGA ---"; regs
echo "--- web ---"; curl -s -m 8 $B/api/status | head -c 170; echo
media-ctl -d /dev/media2 -p 2>/dev/null | grep -A1 'm02_back_FPGA' | tail -1 | sed 's/^/  sensor: /'
echo "--- 抓帧 ---"; shot

echo
echo "############ 2. 切到 4K25 ############"
curl -s -m 40 -X POST -H 'Content-Type: application/json' \
     -d '{"id":"4k25","force":true}' $B/api/mode
echo
echo "  等 8 秒 (300ms 复位窗 + 传感器重锁 + 攒帧)..."
sleep 8
echo "--- FPGA ---"; regs
echo "--- web ---"; curl -s -m 8 $B/api/status | head -c 170; echo
echo "--- video22 ---"; v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | grep -E 'Width/Height' | sed 's/^/  /'
echo "--- 抓帧 ---"; shot

echo
echo "--- 内核日志 (切换后) ---"
dmesg | tail -8 | sed 's/^/  /'
