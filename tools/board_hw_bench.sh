#!/bin/sh
echo "== mppjpegenc caps"
gst-inspect-1.0 mppjpegenc 2>/dev/null | sed -n '/Pad Templates/,/Element Properties/p' | head -40
echo "== rga gst element?"
gst-inspect-1.0 2>/dev/null | grep -iE 'rgaconvert|rga.*convert' | head
echo "== video-enc0 m2m"
v4l2-ctl -d /dev/video-enc0 --info 2>/dev/null | head -12
v4l2-ctl -d /dev/video-enc0 --list-formats-out 2>/dev/null | head -20
echo "== bench: mppjpegenc 1080p (200 frames)"
/usr/bin/time -f "  wall %es cpu %P" gst-launch-1.0 -q videotestsrc num-buffers=200 \
  ! video/x-raw,format=NV12,width=1920,height=1080 \
  ! mppjpegenc ! fakesink sync=false 2>&1 | tail -3
echo "== bench: mppjpegenc 4K (100 frames)"
/usr/bin/time -f "  wall %es cpu %P" gst-launch-1.0 -q videotestsrc num-buffers=100 \
  ! video/x-raw,format=NV12,width=3840,height=2160 \
  ! mppjpegenc ! fakesink sync=false 2>&1 | tail -3
echo "== bench: software jpegenc 1080p (200 frames)"
/usr/bin/time -f "  wall %es cpu %P" gst-launch-1.0 -q videotestsrc num-buffers=200 \
  ! video/x-raw,format=NV12,width=1920,height=1080 \
  ! jpegenc ! fakesink sync=false 2>&1 | tail -3
