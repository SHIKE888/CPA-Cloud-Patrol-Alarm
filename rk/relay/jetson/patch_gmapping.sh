#!/bin/bash
# 修正 gmapping 建图参数（车端用户态，无需 sudo）
# 问题：
#   1) 地图窗口只有 10m x 8m（xmin=-5 xmax=5 ymin=-4 ymax=4）→ 走出范围就崩
#   2) particles=8（默认 30）→ 一匹配不好就丢定位
#   3) linearUpdate=0.05 / angularUpdate=0.0436 → 过于频繁，误差累积
#   4) map_update_interval=0.01 → 地图刷太勤，CPU 高
set -e
F=$HOME/wheeltec_robot/src/turn_on_wheeltec_robot/launch/include/algorithm_gmapping.launch
[ -f "$F" ] || { echo "找不到 $F"; exit 1; }
[ -f "$F.bak_rosrelay" ] || cp "$F" "$F.bak_rosrelay"

sed -i 's|<param name="particles" value="8"/>|<param name="particles" value="30"/>|' "$F"
sed -i 's|<param name="linearUpdate" value="0.05"/>|<param name="linearUpdate" value="0.2"/>|' "$F"
sed -i 's|<param name="angularUpdate" value="0.0436"/>|<param name="angularUpdate" value="0.2"/>|' "$F"
sed -i 's|<param name="map_update_interval" value="0.01"/>|<param name="map_update_interval" value="0.5"/>|' "$F"
sed -i 's|<param name="xmin" value="-5.0"/>|<param name="xmin" value="-20.0"/>|' "$F"
sed -i 's|<param name="ymin" value="-4.0"/>|<param name="ymin" value="-20.0"/>|' "$F"
sed -i 's|<param name="xmax" value="5.0"/>|<param name="xmax" value="20.0"/>|' "$F"
sed -i 's|<param name="ymax" value="4.0"/>|<param name="ymax" value="20.0"/>|' "$F"

echo "== 修改后 =="
grep -n -e 'name="particles"' -e 'name="linearUpdate"' -e 'name="angularUpdate"' \
        -e 'name="map_update_interval"' -e 'name="xmin"' -e 'name="ymin"' \
        -e 'name="xmax"' -e 'name="ymax"' "$F"
