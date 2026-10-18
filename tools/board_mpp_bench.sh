#!/bin/sh
bench() {
  # $1=w $2=h $3=fmt $4=frames
  t0=$(date +%s%N)
  gst-launch-1.0 -q videotestsrc num-buffers=$4 \
    ! video/x-raw,format=$3,width=$1,height=$2 \
    ! mppjpegenc ! fakesink sync=false >/dev/null 2>&1
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  fps=$(echo "scale=1; $4 * 1000 / $ms" | bc)
  echo "mppjpegenc ${1}x${2} $3 : ${ms}ms / $4 frames => ${fps} fps  (${ms}.0ms per frame /$4)"
}
echo "== mppjpegenc"
bench 1920 1080 NV16 300
bench 1920 1080 NV12 300
bench 1728 972 NV16 300
bench 3840 2160 NV16 200
echo "== software jpegenc (gst) 对照"
t0=$(date +%s%N)
gst-launch-1.0 -q videotestsrc num-buffers=100 ! video/x-raw,format=NV12,width=1728,height=972 \
  ! jpegenc ! fakesink sync=false >/dev/null 2>&1
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
echo "jpegenc 1728x972 : ${ms}ms / 100 => $(echo "scale=1; 100000/$ms" | bc) fps"
echo "== 单帧耗时(ms)"
echo "mpp 4K:  $(echo "scale=1; 0" | bc)" 
