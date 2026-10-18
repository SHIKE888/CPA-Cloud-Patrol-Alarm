#!/bin/sh
FB=$(( 1728 * 972 * 3 / 2 ))
echo "frame bytes $FB"
echo "== filesrc + rawvideoparse"
rm -f /tmp/t1.jpg
gst-launch-1.0 -q filesrc location=/tmp/f1728.nv12 blocksize=$FB \
  ! rawvideoparse format=nv12 width=1728 height=972 \
  ! mppjpegenc ! filesink location=/tmp/t1.jpg 2>&1 | tail -3
stat -c 'filesrc+parse -> %s bytes' /tmp/t1.jpg 2>/dev/null

echo "== fdsrc + rawvideoparse (stdin)"
rm -f /tmp/t2.jpg
cat /tmp/f1728.nv12 | gst-launch-1.0 -q fdsrc fd=0 \
  ! rawvideoparse format=nv12 width=1728 height=972 \
  ! mppjpegenc ! filesink location=/tmp/t2.jpg 2>&1 | tail -3
stat -c 'fdsrc+parse -> %s bytes' /tmp/t2.jpg 2>/dev/null

echo "== fdsrc + rawvideoparse -> fdsink (stdout)"
cat /tmp/f1728.nv12 | gst-launch-1.0 -q fdsrc fd=0 \
  ! rawvideoparse format=nv12 width=1728 height=972 \
  ! mppjpegenc ! fdsink fd=1 > /tmp/t3.jpg 2>/dev/null
stat -c 'fdsrc+parse+fdsink -> %s bytes' /tmp/t3.jpg 2>/dev/null
