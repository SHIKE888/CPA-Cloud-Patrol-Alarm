#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修好 algorithm_gmapping.launch 第 10 行（map_update_interval），
上一版 sed 用 `.` 通配符把引号吃掉了。"""
import os

P = os.path.expanduser(
    '~/wheeltec_robot/src/turn_on_wheeltec_robot/launch/include/algorithm_gmapping.launch')
GOOD = '    <param name="map_update_interval" value="0.5"/>'

with open(P) as f:
    lines = f.read().splitlines()

idx = None
for i, ln in enumerate(lines):
    if 'map_update_interval' in ln:
        idx = i
        break
if idx is None:
    raise SystemExit('没找到 map_update_interval 行')

print('原行:', lines[idx])
lines[idx] = GOOD
with open(P, 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('新行:', GOOD)

# 校验：整段 XML 里不应再出现 value=. 这种畸形
with open(P) as f:
    bad = [ln for ln in f if 'value=.' in ln]
print('畸形行数:', len(bad))
