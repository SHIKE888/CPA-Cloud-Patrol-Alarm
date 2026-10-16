#!/bin/bash
# 只读探测: media 拓扑 + 各路 video/subdev 的当前格式
# 目的: 找到能真正改分辨率的那一环 (v4l2-ctl 改 /dev/videoN 会被 sensor subdev 拉回去)
echo "=================== media-ctl -d /dev/media2 -p ==================="
media-ctl -d /dev/media2 -p 2>&1

echo
echo "=================== 设备节点 ==================="
for d in /dev/video* /dev/v4l-subdev*; do
  [ -e "$d" ] || continue
  n=$(v4l2-ctl -d "$d" --info 2>/dev/null | grep -i 'Card type' | sed 's/.*: //')
  echo "  $d  ->  $n"
done

echo
echo "=================== /dev/video22 当前格式 ==================="
v4l2-ctl -d /dev/video22 --get-fmt-video 2>&1

echo
echo "=================== 各 subdev 的 fmt (MEDIA_IOC) ==================="
media-ctl -d /dev/media2 --print-dot 2>/dev/null | head -1 >/dev/null
for e in $(media-ctl -d /dev/media2 -p 2>/dev/null | grep -oP '^\s*-\s*entity\s+\K\d+' ); do
  :
done
# 直接列出每个 entity 的 pad 格式
media-ctl -d /dev/media2 -p 2>/dev/null | awk '
  /^- entity/ { ent=$3 }
  /device node name/ { node=$4 }
  /fmt:/ { print "  " ent, "->", node, ":", $0 }
'
