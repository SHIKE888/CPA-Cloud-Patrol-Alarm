#!/bin/sh
PY=/opt/miniforge3/envs/mlk-ov/bin/python
echo "=== gi / Gst ==="
$PY -c "import gi; print('gi ok')" 2>&1 | tail -2
$PY -c "import gi; gi.require_version('Gst','1.0'); from gi.repository import Gst; Gst.init(None); print('gst', Gst.version_string())" 2>&1 | tail -2
echo "=== pip ==="
$PY -m pip list 2>/dev/null | grep -iE 'pygobject|gstreamer|rga|mpp|numpy|opencv'
echo "=== mppjpegenc caps ==="
gst-inspect-1.0 mppjpegenc 2>/dev/null | sed -n '/Pad Templates/,/Element has/p' | head -30
echo "=== props ==="
gst-inspect-1.0 mppjpegenc 2>/dev/null | sed -n '/Element Properties/,/^$/p' | head -20
