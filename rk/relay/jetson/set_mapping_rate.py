#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 gmapping 的 map_update_interval 设为指定值（默认 0.1s = 10Hz）。

按行内容定位，避免 sed 的 `.` 通配符误伤 resampleThreshold 等其它 0.5。
用法： python3 set_mapping_rate.py [间隔秒]
"""
import os
import sys

VAL = sys.argv[1] if len(sys.argv) > 1 else '0.1'
P = os.path.expanduser(
    '~/wheeltec_robot/src/turn_on_wheeltec_robot/launch/include/algorithm_gmapping.launch')
NEW = '    <param name="map_update_interval" value="%s"/>' % VAL

with open(P) as f:
    lines = f.read().splitlines()

hit = 0
for i, ln in enumerate(lines):
    if 'map_update_interval' in ln:
        print('原:', ln.strip())
        lines[i] = NEW
        hit += 1
if not hit:
    raise SystemExit('没找到 map_update_interval')

with open(P, 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('新:', NEW)
