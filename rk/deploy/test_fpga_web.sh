#!/bin/sh
# test_fpga_web.sh —— 验证网页的 /api/fpga，并检查帧计数读数是否稳定
PY=/opt/miniforge3/envs/mlk-ov/bin/python
URL=http://127.0.0.1:9012/api/fpga

echo "=============================================="
echo " 1) 接口功能测试"
echo "=============================================="
cd /root/rk/deploy && "$PY" test_fpga_api.py

echo
echo "=============================================="
echo " 2) 帧计数连读 (60fps, 间隔 1.2s -> 应约 +72)"
echo "=============================================="
i=1
while [ $i -le 6 ]; do
    printf "  [%d] FRAME_CNT = " "$i"
    curl -s --max-time 6 "$URL" | sed -n 's/.*"FRAME_CNT": \([0-9]*\).*/\1/p'
    sleep 1.2
    i=$((i + 1))
done

echo
echo "=============================================="
echo " 3) 心跳连读 (每 256 个 25MHz 周期 +1, 应一直在变)"
echo "=============================================="
i=1
while [ $i -le 6 ]; do
    printf "  [%d] HEARTBEAT = " "$i"
    curl -s --max-time 6 "$URL" | sed -n 's/.*"HEARTBEAT": \([0-9]*\).*/\1/p'
    sleep 0.4
    i=$((i + 1))
done

echo
echo "=============================================="
echo " 4) burst 读 (API) vs 逐字节读 (fpga_cfg.py) 对比"
echo "=============================================="
echo "  API burst 4 字节:"
printf "    FRAME_CNT = "
curl -s --max-time 6 "$URL" | sed -n 's/.*"FRAME_CNT": \([0-9]*\).*/\1/p'
echo "  fpga_cfg.py 逐字节读 4 次:"
/usr/bin/python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -E '0xB[89AB]'
echo "  (两者应完全一致; 若高字节不同就是 burst 读有问题)"
