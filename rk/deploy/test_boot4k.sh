#!/bin/bash
# 验证 "FPGA 上电直接以 4K25 启动" (V26 实验)
#
# 为什么试这个: 两轮实测显示 "切到 binning 能成功、切到 4K 不能"(写 RES_MODE=2
# 后 RX 必死, 而写 RES_MODE=0 总能把 RX 拉回来) => 怀疑是 **4K 模式本身**,
# 不是切换机制。厂商 PCIe 工程的默认值就是 4K@30fps(上电直接 4K),
# 所以这里让 FPGA 上电就走 4K 初始化表, 一次性验证 4K 的表/几何/链路。
#
# 此脚本不写 FPGA 的 RES_MODE(保持上电值), 只改 RK 侧 pipeline + web 尺寸。
B=http://127.0.0.1:9012
M=/dev/media2
SENSOR='"m02_back_FPGA-MIPI 9-001a"'
DPHY='"rockchip-csi2-dphy3"'
CSI2='"rockchip-mipi-csi2"'

echo "############ 1. FPGA 状态 (期望 RES_MODE=2) ############"
python3 /root/rk/deploy/fpga_cfg.py dump 2>/dev/null | grep -E '0xE0 |0xD4|0xD5|帧计数'

echo
echo "############ 2. RK 侧整条 pipeline 设成 3840x2160 ############"
pkill -f mipi_webstream.py; sleep 1
for spec in "$SENSOR:0" "$DPHY:0" "$CSI2:0"; do
  echo -n "  $spec -> "
  media-ctl -d $M --set-v4l2 "$spec[fmt:YUYV8_2X8/3840x2160]" 2>&1 && echo ok
done

echo
echo "############ 3. 以 3840x2160 起 web ############"
cd /root/rk/web
nohup ./start_webstream.sh /dev/video22 9012 --width 3840 --height 2160 \
      > /tmp/webstream.log 2>&1 &
sleep 15

echo
echo "############ 4. 结果 ############"
echo "--- FPGA (★ 帧计数应约 31fps = 4K30.9 的传感器速率; 0xD4/0xD5 应 ~966) ---"
python3 /root/rk/deploy/fpga_cfg.py dump 2>/dev/null | grep -E '0xE0 |0xD4|0xD5|帧计数'
echo "--- web ---"
curl -s -m 8 $B/api/status | head -c 180; echo
echo "--- video22 ---"
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | grep -E 'Width/Height' | sed 's/^/  /'
echo "--- 抓帧 ---"
curl -s -m 25 -o /tmp/boot4k.jpg $B/snapshot.jpg
echo "  字节数 = $(stat -c %s /tmp/boot4k.jpg)"
/opt/miniforge3/envs/mlk-ov/bin/python - <<'PYEOF'
import cv2
i = cv2.imread('/tmp/boot4k.jpg')
if i is None:
    print("  !! 没抓到帧")
else:
    print("  尺寸 %s   亮度 %.1f" % (i.shape, i.mean()))
PYEOF
echo "--- web 日志尾 ---"
tail -8 /tmp/webstream.log | sed 's/^/  /'
