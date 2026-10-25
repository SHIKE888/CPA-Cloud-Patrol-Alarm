#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""降低 gmapping 单帧计算量，提高地图刷新率（实时性优先）。

实测：slam_gmapping 单核 106%（6 核整机只 23%），是单核瓶颈。
主要手段：
  lskip      : 每 N 个激光点取 1 个（0=不跳，2=用 1/3 的点）
  particles  : 粒子数（30 → 15）
  iterations : scan matching 精化次数（5 → 4）
  maxUrange  : 只用 3.5m 内的点

用法： python3 set_gmapping_perf.py [lskip] [particles] [iterations] [maxUrange]
"""
import os
import sys

L = sys.argv[1] if len(sys.argv) > 1 else '2'
P = sys.argv[2] if len(sys.argv) > 2 else '15'
I = sys.argv[3] if len(sys.argv) > 3 else '4'
U = sys.argv[4] if len(sys.argv) > 4 else '3.5'

PATH = os.path.expanduser(
    '~/wheeltec_robot/src/turn_on_wheeltec_robot/launch/include/algorithm_gmapping.launch')

MAP = {
    'lskip': L,
    'particles': P,
    'iterations': I,
    'maxUrange': U,
}
DONE = {}

with open(PATH) as f:
    lines = f.read().splitlines()

for i, ln in enumerate(lines):
    for key, val in MAP.items():
        if ('name="%s"' % key) in ln:
            old = ln.strip()
            lines[i] = '    <param name="%s" value="%s"/>' % (key, val)
            DONE[key] = (old, lines[i].strip())

with open(PATH, 'w') as f:
    f.write('\n'.join(lines) + '\n')

for k in MAP:
    if k in DONE:
        print('%s: %s  ->  %s' % (k, DONE[k][0], DONE[k][1]))
    else:
        print('%s: 没找到（跳过）' % k)
