#!/bin/bash
# 板上 NPU / Python 环境探测（用于 RK3576 AI 部署选型）
echo "=== kernel/os"
uname -r
cat /etc/os-release 2>/dev/null | sed -n '1,2p'
echo "=== cpu/mem"
nproc
free -m | head -2
echo "=== rknpu driver"
cat /sys/kernel/debug/rknpu/version 2>/dev/null
cat /sys/kernel/debug/rknpu/freq 2>/dev/null
echo "=== librknnrt"
ls -l /usr/lib/librknnrt.so /usr/lib/librknn_api.so 2>/dev/null
strings /usr/lib/librknnrt.so 2>/dev/null | grep -Ei "librknnrt version|rknn runtime|version:" | head -5
echo "=== video nodes"
ls /dev/video* 2>/dev/null | tr '\n' ' '
echo
echo "=== python A: miniforge mlk-ov"
/opt/miniforge3/envs/mlk-ov/bin/python -c "import sys;print(sys.version)" 2>&1 | head -1
/opt/miniforge3/envs/mlk-ov/bin/python -c "import rknnlite,sys;print('rknnlite:',rknnlite.__file__)" 2>&1 | tail -1
/opt/miniforge3/envs/mlk-ov/bin/python -m pip list 2>/dev/null | grep -Ei "rknn|opencv|numpy|pillow"
echo "=== python B: /usr/bin/python3"
/usr/bin/python3 -c "import sys;print(sys.version)" 2>&1 | head -1
/usr/bin/python3 -c "import rknnlite,sys;print('rknnlite:',rknnlite.__file__)" 2>&1 | tail -1
/usr/bin/python3 -m pip list 2>/dev/null | grep -Ei "rknn|opencv|numpy"
echo "=== other rknn libs on board"
find / -xdev -name "librknn*.so" -o -xdev -name "rknn*.whl" 2>/dev/null | head -20
echo "=== /root/rk/web"
ls -l /root/rk/web 2>/dev/null
