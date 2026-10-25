#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""调整 gmapping 地图范围与发布间隔。

背景：地图范围从 ±5/±4 放大到 ±20 后，格子数 1.7 万 → 64 万，
      实测 gmapping 一帧要 1.3~7 秒（单核实测 106%，整机才 23%）。
      折中为 ±10 m（400x400 = 16 万格），既能建大一点的图，也不至于卡死。

用法： python3 set_map_bounds.py [半宽m] [map_update_interval]
"""
import os
import sys

B = sys.argv[1] if len(sys.argv) > 1 else '10'
UPD = sys.argv[2] if len(sys.argv) > 2 else '0.5'

P = os.path.expanduser(
    '~/wheeltec_robot/src/turn_on_wheeltec_robot/launch/include/algorithm_gmapping.launch')

NEW = {
    'xmin': '-%s' % B,
    'ymin': '-%s' % B,
    'xmax': B,
    'ymax': B,
    'map_update_interval': UPD,
}

with open(P) as f:
    lines = f.read().splitlines()

done = []
for i, ln in enumerate(lines):
    for k, v in NEW.items():
        if ('name="%s"' % k) in ln:
            print('%s: %s -> %s' % (k, ln.strip(), v))
            lines[i] = '    <param name="%s" value="%s"/>' % (k, v)
            done.append(k)

with open(P, 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('已处理:', ', '.join(done))
