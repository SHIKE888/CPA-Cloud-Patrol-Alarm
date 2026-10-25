#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""调整 gmapping 的更新阈值，让地图尽量实时。

linearUpdate / angularUpdate 决定「走多远/转多少才处理一帧 scan」：
  0.2 m / 0.2 rad 太粗，慢速移动时几秒才更新一次地图
  0.05 m / 0.05 rad ≈ 雷达每帧（10 Hz）都处理

用法： python3 set_mapping_updates.py [线性m] [角度rad]
"""
import os
import sys

LIN = sys.argv[1] if len(sys.argv) > 1 else '0.05'
ANG = sys.argv[2] if len(sys.argv) > 2 else '0.05'

P = os.path.expanduser(
    '~/wheeltec_robot/src/turn_on_wheeltec_robot/launch/include/algorithm_gmapping.launch')

with open(P) as f:
    lines = f.read().splitlines()

changed = 0
for i, ln in enumerate(lines):
    if 'name="linearUpdate"' in ln:
        print('linearUpdate 原:', ln.strip())
        lines[i] = '    <param name="linearUpdate" value="%s"/>' % LIN
        changed += 1
    elif 'name="angularUpdate"' in ln:
        print('angularUpdate 原:', ln.strip())
        lines[i] = '    <param name="angularUpdate" value="%s"/>' % ANG
        changed += 1

if changed != 2:
    raise SystemExit('没找全两行（changed=%d）' % changed)

with open(P, 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('已改为 linearUpdate=%s  angularUpdate=%s' % (LIN, ANG))
