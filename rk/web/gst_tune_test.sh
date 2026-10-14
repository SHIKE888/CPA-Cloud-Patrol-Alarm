#!/bin/bash
#=============================================================================
# gst_tune_test.sh —— 原生 GStreamer 管线吞吐测试 + 颜色对照
#
#   ./gst_tune_test.sh [/dev/video22]
#
# 目的: 找出"同等画质下帧率最高"的管线组合。
#   OpenCV 后端在 1080p 上要 100ms/帧; 原生 GStreamer 全部是 SIMD/多线程 C,
#   理论上快很多。关键是颜色问题能否用 capssetter 重新标注 colorimetry 解决。
#=============================================================================
DEV="${1:-/dev/video22}"
N=150
OUT=/tmp/gsttest

need() { command -v "$1" >/dev/null 2>&1 || { echo "!! 缺少 $1"; exit 1; }; }
need gst-launch-1.0

t() {
    local name="$1"; shift
    local t0 t1 ms rc
    t0=$(date +%s%N)
    gst-launch-1.0 -q "$@" >/dev/null 2>&1
    rc=$?
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    if [ $rc -ne 0 ]; then
        printf '  %-40s  失败(rc=%d)\n' "$name" "$rc"
        return
    fi
    awk -v n="$N" -v m="$ms" -v s="$name" \
        'BEGIN{printf "  %-40s %6d ms  %6.1f fps\n", s, m, n*1000/m}'
}

echo "设备: $DEV    每组 $N 帧"
echo
echo "=== A. 原生管线吞吐 ==="

t "1) v4l2src -> jpegenc (1080p 直出)" \
  v4l2src device=$DEV num-buffers=$N ! \
  video/x-raw,width=1920,height=1080 ! \
  jpegenc quality=80 ! fakesink

t "2) + videoscale 720p" \
  v4l2src device=$DEV num-buffers=$N ! \
  video/x-raw,width=1920,height=1080 ! \
  videoscale ! video/x-raw,width=1280,height=720 ! \
  jpegenc quality=80 ! fakesink

t "3) 2) + capssetter(colorimetry=bt709)" \
  v4l2src device=$DEV num-buffers=$N ! \
  video/x-raw,width=1920,height=1080 ! \
  capssetter caps=video/x-raw,colorimetry=bt709 join=true ! \
  videoscale ! video/x-raw,width=1280,height=720 ! \
  videoconvert ! \
  jpegenc quality=80 ! fakesink

t "4) 3) + videobalance+gamma+videoflip" \
  v4l2src device=$DEV num-buffers=$N ! \
  video/x-raw,width=1920,height=1080 ! \
  capssetter caps=video/x-raw,colorimetry=bt709 join=true ! \
  videoscale ! video/x-raw,width=1280,height=720 ! \
  videoconvert ! videobalance ! gamma ! videoflip method=none ! \
  jpegenc quality=80 ! fakesink

echo
echo "=== B. 颜色对照 (取回两张 JPEG 自己看) ==="
rm -rf $OUT; mkdir -p $OUT

echo "  [1] 加 capssetter -> bt709 (期望: 颜色正确)"
gst-launch-1.0 -q v4l2src device=$DEV num-buffers=40 ! \
  video/x-raw,width=1920,height=1080 ! \
  capssetter caps=video/x-raw,colorimetry=bt709 join=true ! \
  videoscale ! video/x-raw,width=1280,height=720 ! \
  videoconvert ! jpegenc quality=90 ! \
  multifilesink location=$OUT/ok_%03d.jpg
echo "     -> $(ls $OUT/ok_*.jpg 2>/dev/null | tail -1)"

echo "  [2] 不加 (驱动报 Default, 通常按 bt601-limited 处理)"
gst-launch-1.0 -q v4l2src device=$DEV num-buffers=40 ! \
  video/x-raw,width=1920,height=1080 ! \
  videoscale ! video/x-raw,width=1280,height=720 ! \
  videoconvert ! jpegenc quality=90 ! \
  multifilesink location=$OUT/plain_%03d.jpg
echo "     -> $(ls $OUT/plain_*.jpg 2>/dev/null | tail -1)"

echo
echo "取回: scp afc03:$OUT/ok_030.jpg 和 afc03:$OUT/plain_030.jpg"
