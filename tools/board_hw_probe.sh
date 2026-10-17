#!/bin/sh
echo "== devices"
ls -l /dev/rga /dev/mpp_service 2>&1 | head
ls /dev/video* 2>/dev/null | tr '\n' ' '; echo
echo "== libs"
ls /usr/lib/aarch64-linux-gnu/ 2>/dev/null | grep -iE 'rga|mpp|rockchip' | head -20
ls /usr/lib/ 2>/dev/null | grep -iE 'rga|mpp|rockchip' | head -20
echo "== bins"
which mpp_jpegenc mpitest gst-launch-1.0 2>/dev/null
echo "== gst plugins (mpp/rga)"
gst-inspect-1.0 2>/dev/null | grep -iE 'mpp|rga' | head -20
echo "== python modules (mlk-ov)"
/opt/miniforge3/envs/mlk-ov/bin/python - <<'PY'
for m in ("rga", "mpp", "rockchip_mpp", "gi"):
    try:
        __import__(m)
        print("OK  ", m)
    except Exception as e:
        print("FAIL", m, type(e).__name__)
PY
echo "== v4l2 m2m encoders"
for d in /dev/video*; do
  cap=$(v4l2-ctl -d $d --info 2>/dev/null | grep -i 'driver name' | head -1)
  case "$cap" in
    *rkvenc*|*mpp*|*jpeg*|*rkvdec*) echo "$d $cap" ;;
  esac
done
echo "== kernel modules"
lsmod 2>/dev/null | grep -iE 'rga|mpp|rkvdec|rkvenc' | head
