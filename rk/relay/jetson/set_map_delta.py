#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""调整 gmapping 的地图分辨率 delta（0.05 → 0.1），格子数降 4 倍。

实测：地图 400x400（16 万格）时 slam_gmapping 单核 100%，16 秒才出 1 帧地图。
格子数是主因，降 delta 是最直接的手段（代价：地图边缘粗 5cm）。

用法： python3 set_map_delta.py [delta] [map_update_interval]
"""
import os
import sys

D = sys.argv[1] if len(sys.argv) > 1 else '0.1'
UPD = sys.argv[2] if len(sys.argv) > 2 else '0.2'

P = os.path.expanduser(
    '~/wheeltec_robot/src/turn_on_wheeltec_robot/launch/include/algorithm_gmapping.launch')

NEW = {'delta': D, 'map_update_interval': UPD}

with open(P) as f:
    lines = f.read().splitlines()

for i, ln in enumerate(lines):
    for k, v in NEW.items():
        if ('name="%s"' % k) in ln:
            print('%s: %s -> %s' % (k, ln.strip(), v))
            lines[i] = '    <param name="%s" value="%s"/>' % (k, v)

with open(P, 'w') as f:
    f.write('\n'.join(lines) + '\n')
