#!/bin/bash
#=============================================================================
# env_check.sh —— 检查 RK3576 上运行 mipi_webstream.py 所需的环境
#
#   ./env_check.sh
#=============================================================================

echo "=== 系统 ==="
if [ -f /proc/device-tree/model ]; then
    printf '  model : '; tr -d '\0' < /proc/device-tree/model; echo
fi
printf '  kernel: '; uname -r
printf '  arch  : '; uname -m

echo
echo "=== Python 解释器 (逐个探测依赖) ==="
for py in python3 /opt/miniforge3/envs/mlk-ov/bin/python \
          /opt/miniforge3/envs/*/bin/python; do
    command -v "$py" >/dev/null 2>&1 || continue
    echo "--- $py ---"
    "$py" - <<'PY'
import importlib, sys
print("  python  %s" % sys.version.split()[0])
print("  exe     %s" % sys.executable)
for name, attr in (("cv2", "__version__"), ("numpy", "__version__"),
                   ("PIL", "__version__")):
    try:
        m = importlib.import_module(name)
        print("  %-8s OK   %s" % (name, getattr(m, attr, "")))
    except Exception as e:
        print("  %-8s --   %s" % (name, e))
try:
    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst
    Gst.init(None)
    print("  %-8s OK   (可用 Gst.parse_launch 在线调参)" % "gi/Gst")
except Exception as e:
    print("  %-8s --   %s" % ("gi/Gst", e))
PY
done
echo
echo "  提示: start_webstream.sh 会自动挑 '能 import cv2' 的解释器;"
echo "        也可手动指定: PYTHON=/opt/miniforge3/envs/mlk-ov/bin/python ./start_webstream.sh"

echo
echo "=== GStreamer 元素 ==="
for e in v4l2src videoconvert videoscale videobalance gamma videoflip \
         jpegenc multipartmux fdsink tcpserversink kmssink; do
    printf '  %-16s' "$e"
    if gst-inspect-1.0 "$e" >/dev/null 2>&1; then echo OK; else echo MISSING; fi
done

echo
echo "=== 采集节点 (Card / Bus / 是否 Multiplanar) ==="
for v in /dev/video*; do
    info=$(v4l2-ctl -d "$v" --info 2>/dev/null) || continue
    card=$(printf '%s\n' "$info"  | sed -n 's/.*Card type *: *//p')
    bus=$(printf '%s\n'  "$info"  | sed -n 's/.*Bus info *: *//p')
    mp=$(printf '%s\n'   "$info"  | grep -c 'Multiplanar')
    [ -n "$card" ] && printf '  %-14s %-10s %-30s multiplanar=%s\n' "$v" "$card" "$bus" "$mp"
done

echo
echo "=== /dev/video22 支持的格式 ==="
v4l2-ctl -d /dev/video22 --list-formats 2>/dev/null | grep -E 'Type:|^\['
