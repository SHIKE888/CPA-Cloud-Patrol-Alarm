#!/bin/sh
# probe_env.sh —— 探查板端视频抓取环境 (预处理效果验证用)
echo "=== 1) 相关进程 ==="
ps aux | grep -E '[m]ipi|[g]st|[k]ms' | head -8
echo
echo "=== 2) 可用工具 ==="
for t in v4l2-ctl ffmpeg gst-launch-1.0 i2ctransfer python3; do
  printf "  %-16s " "$t"
  command -v "$t" || echo "-"
done
echo
echo "=== 3) video 节点 ==="
ls /dev/video* 2>/dev/null | tr '\n' ' '
echo
echo
echo "=== 4) video22 格式 ==="
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1 | head -8
echo
echo "=== 5) python 模块 ==="
for m in cv2 numpy PIL gi; do
  printf "  %-8s " "$m"
  /usr/bin/python3 -c "import $m; print('OK')" 2>/dev/null || echo "-"
done
echo
echo "=== 6) 备用 python (miniforge) ==="
/opt/miniforge3/envs/mlk-ov/bin/python -c "import cv2,numpy;print('cv2',cv2.__version__)" 2>&1 | head -2
