#!/bin/sh
try() {
  # $1=w $2=h
  rm -f /tmp/t.jpg
  out=$(gst-launch-1.0 -q filesrc location=/tmp/f1728.nv12 blocksize=$(( $1 * $2 * 3 / 2 )) \
        ! video/x-raw,format=NV12,width=$1,height=$2 \
        ! mppjpegenc ! filesink location=/tmp/t.jpg 2>&1 | tail -2)
  sz=$(stat -c %s /tmp/t.jpg 2>/dev/null || echo 0)
  echo "${1}x${2} -> $(stat -c %s /tmp/t.jpg 2>/dev/null || echo FAIL)"
}
echo "--- 同尺寸, 有/无 framerate"
gst-launch-1.0 -q filesrc location=/tmp/f1728.nv12 ! video/x-raw,format=NV12,width=1728,height=972 ! mppjpegenc ! filesink location=/tmp/a.jpg 2>&1 | tail -2
stat -c 'no-framerate -> %s' /tmp/a.jpg 2>/dev/null
gst-launch-1.0 -q filesrc location=/tmp/f1728.nv12 ! video/x-raw,format=NV12,width=1728,height=972,framerate=25/1 ! mppjpegenc ! filesink location=/tmp/b.jpg 2>&1 | tail -2
stat -c 'with-framerate -> %s' /tmp/b.jpg 2>/dev/null
echo "--- videotestsrc 同尺寸对照"
gst-launch-1.0 -q videotestsrc num-buffers=1 ! video/x-raw,format=NV12,width=1728,height=972 ! mppjpegenc ! filesink location=/tmp/c.jpg 2>&1 | tail -2
stat -c 'vts 1728x972 -> %s' /tmp/c.jpg 2>/dev/null
gst-launch-1.0 -q videotestsrc num-buffers=1 ! video/x-raw,format=NV12,width=1728,height=976 ! mppjpegenc ! filesink location=/tmp/d.jpg 2>&1 | tail -2
stat -c 'vts 1728x976 -> %s' /tmp/d.jpg 2>/dev/null
