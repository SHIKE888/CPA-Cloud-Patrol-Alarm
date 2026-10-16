#!/bin/bash
# 切换分辨率模式: FPGA RES_MODE (I2C 0xE0) + RK 侧整条 media pipeline
#
# 为什么不能只用 v4l2-ctl 改 /dev/video22:
#   rkcif 会把尺寸从 **sensor subdev** (m02_back_FPGA-MIPI 9-001a) 拉回来,
#   所以必须先用 media-ctl 把 sensor 那一环设成目标尺寸。
#
# 用法:  switch_res_mode.sh 1080p | 4k25 | 4k30
#        switch_res_mode.sh status          # 只看不改
set -u
MARG=${1:-status}
B=http://127.0.0.1:9012
M=/dev/media2
SENSOR='"m02_back_FPGA-MIPI 9-001a"'
DPHY='"rockchip-csi2-dphy3"'
CSI2='"rockchip-mipi-csi2"'
PY=/opt/miniforge3/envs/mlk-ov/bin/python

case "$MARG" in
  1080p) W=1920; H=1080; RESMODE=0; NAME="1920x1080@60" ;;
  4k25)  W=3840; H=2160; RESMODE=2; NAME="3840x2160@25" ;;
  4k30)  W=3840; H=2160; RESMODE=1; NAME="3840x2160@30" ;;
  status) W=; H=; RESMODE=; NAME="(只查看)" ;;
  *) echo "用法: $0 1080p|4k25|4k30|status"; exit 2 ;;
esac

show() {
  echo "  --- /dev/video22 ---"
  v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | sed 's/^/    /'
  echo "  --- sensor subdev4 ---"
  v4l2-ctl -d /dev/v4l-subdev4 --get-subdev-fmt pad=0 2>&1 \
    | grep -E 'Width/Height|Mediabus' | sed 's/^/    /'
  echo "  --- FPGA 寄存器 ---"
  python3 /root/rk/deploy/fpga_cfg.py get 0xE0 2>&1 | sed 's/^/    /'
  echo "  --- 帧计数 (两次采样) ---"
  a=$(python3 -c "
import fcntl
f=open('/dev/i2c-9','r+b',buffering=0); fcntl.ioctl(f,0x0703,0x40)
def rd(r):
    fcntl.ioctl(f,0x0703,0x40); f.write(bytes([r])); return f.read(1)[0]
print(rd(0xB8)|rd(0xB9)<<8|rd(0xBA)<<16|rd(0xBB)<<24)")
  sleep 2
  b=$(python3 -c "
import fcntl
f=open('/dev/i2c-9','r+b',buffering=0); fcntl.ioctl(f,0x0703,0x40)
def rd(r):
    fcntl.ioctl(f,0x0703,0x40); f.write(bytes([r])); return f.read(1)[0]
print(rd(0xB8)|rd(0xB9)<<8|rd(0xBA)<<16|rd(0xBB)<<24)")
  echo "    $a -> $b  (2s 内 +$((b-a)) 帧 => $(( (b-a)/2 )) fps)"
}

if [ "$MARG" = "status" ]; then
  show
  exit 0
fi

echo "=================== 切到 $NAME ==================="

echo "[1/6] 停 web 采集 (释放 /dev/video22)"
pkill -f mipi_webstream.py
sleep 1
if pgrep -f mipi_webstream.py >/dev/null; then
  echo "     还在, 强制杀"; pkill -9 -f mipi_webstream.py; sleep 1
fi

echo "[2/6] 写 FPGA RES_MODE=0xE0 <- $RESMODE"
python3 /root/rk/deploy/fpga_cfg.py set 0xE0 "$RESMODE" 2>&1 | sed 's/^/     /'
echo "     等复位窗 + 几帧 (80ms 窗, 4K 一帧 40ms)"
sleep 1.5

echo "[3/6] 设 sensor subdev (必须先设它, 否则 rkcif 会把尺寸拉回去)"
media-ctl -d $M --set-v4l2 "$SENSOR:0[fmt:YUYV8_2X8/${W}x${H}]" 2>&1 | sed 's/^/     /'

echo "[4/6] 往下游传播 (dphy3 / csi2)"
media-ctl -d $M --set-v4l2 "$DPHY:0[fmt:YUYV8_2X8/${W}x${H}]" 2>&1 | sed 's/^/     /'
media-ctl -d $M --set-v4l2 "$DPHY:1[fmt:YUYV8_2X8/${W}x${H}]" 2>&1 | sed 's/^/     /'
media-ctl -d $M --set-v4l2 "$CSI2:0[fmt:YUYV8_2X8/${W}x${H}]" 2>&1 | sed 's/^/     /'

echo "[5/6] 起 web"
cd /root/rk/web
nohup ./start_webstream.sh > /tmp/webstream.log 2>&1 &
sleep 10

echo "[6/6] 结果"
show

echo "  --- 抓一帧看画面 ---"
curl -s -m 20 --output /tmp/mode.jpg "$B/snapshot.jpg"
$PY - <<'EOF'
import cv2
i = cv2.imread('/tmp/mode.jpg', cv2.IMREAD_GRAYSCALE)
if i is None:
    print("    !! 没抓到帧")
else:
    h, w = i.shape
    print("    JPEG %dx%d  平均亮度=%.1f  (min %d max %d)"
          % (w, h, i.mean(), i.min(), i.max()))
EOF
echo
echo "  --- web 启动日志尾部 ---"
tail -8 /tmp/webstream.log | sed 's/^/    /'
