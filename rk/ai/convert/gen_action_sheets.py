#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_action_sheets.py —— 为每个动作生成一张「实例骨架图」，并汇总成 markdown。

为什么用渲染而不是找实拍图：动作规则是靠**骨架几何**判定的，示意图把
"这个动作在骨架空间长什么样"直接画出来，比照片更能说明判据。
绘制直接复用线上的 `det_core.draw_person`（同一个 `SKELETON` 拓扑 + 同一套配色），
所以图和真实画面里看到的一模一样。

用法（板上或任何有 cv2 的地方）:
    python gen_action_sheets.py [输出目录]
默认输出到 ./action_sheets/，并在该目录的上一级生成 ACTIONS.md。
"""
from __future__ import annotations

import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join(_HERE, '..', 'board'), _HERE, '/root/rk/ai/board'):
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)

import cv2  # noqa: E402
import det_core as dc  # noqa: E402
from action_rules import ACTION_META  # noqa: E402

W, H = 420, 560
OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'action_sheets')

# ---- 通用直立姿势（脚在 y=500，头顶 y=95）
BASE = {0: (210, 95), 5: (185, 145), 6: (235, 145), 7: (172, 215), 8: (248, 215),
        9: (165, 275), 10: (255, 275), 11: (190, 300), 12: (230, 300),
        13: (188, 400), 14: (232, 400), 15: (186, 500), 16: (234, 500)}


def mk(**over):
    d = dict(BASE)
    for k, v in over.items():
        d[int(k.lstrip('k'))] = v
    return d


# label -> (骨架点, 箭头[(起点, 终点)], 判定说明)
SHEETS = [
    # ---------------- 报警级
    ('fall', mk(k0=(330, 250), k5=(290, 235), k6=(300, 275), k7=(250, 230),
                k8=(255, 280), k9=(210, 225), k10=(215, 285), k11=(170, 250),
                k12=(180, 280), k13=(110, 265), k14=(120, 285),
                k15=(60, 275), k16=(70, 290)),
     [((250, 175), (200, 265))],
     '躯干与竖直夹角 > 45°，且髋高在 1.2s 内骤降 > 0.05 身高；持续 0.35s'),
    ('lying', mk(k0=(350, 300), k5=(310, 285), k6=(320, 325), k7=(270, 280),
                 k8=(275, 330), k9=(230, 275), k10=(235, 335), k11=(190, 290),
                 k12=(200, 325), k13=(130, 300), k14=(140, 325),
                 k15=(70, 310), k16=(80, 330)),
     [],
     '躯干夹角 > 65° 持续 2.5s（长时间倒地不起）'),
    ('climb', mk(k0=(210, 120), k5=(185, 165), k6=(235, 165), k7=(175, 120),
                 k8=(245, 120), k9=(170, 70), k10=(250, 70), k11=(190, 290),
                 k12=(230, 290), k13=(200, 370), k14=(225, 370),
                 k15=(215, 440), k16=(235, 440)),
     [((210, 330), (210, 250))],
     '双手高于肩线，且（髋部 1.2s 内抬升 > 0.18 身高 或 脚高于髋）；持续 0.4s'),
    ('fight', mk(k0=(210, 95), k7=(155, 110), k8=(265, 190),
                 k9=(140, 70), k10=(280, 240)),
     [((150, 90), (120, 60))],
     '腕部速度 > 5 身高/秒（**双手**都在高频挥动）；持续 0.4s'),
    ('swing', mk(k8=(290, 120), k10=(320, 200)),
     [((255, 105), (325, 205))],
     '**单侧**手腕 0.13s 内位移 > 0.45 身高，另一侧 < 该值 50%；持续 0.15s'),
    ('throw', mk(k8=(265, 110), k10=(270, 50)),
     [((285, 190), (272, 45))],
     '手腕 0.13s 内**上撩** > 0.35 身高，且双手已过肩；持续 0.1s'),
    # ---------------- 提醒级
    ('intrude', mk(), [], '脚部关键点落入警戒多边形，持续 0.3s'),
    ('run', mk(k0=(215, 90), k5=(190, 140), k6=(240, 140), k7=(170, 120),
               k8=(260, 175), k9=(155, 95), k10=(275, 225), k11=(195, 290),
               k12=(230, 295), k13=(215, 360), k14=(225, 405),
               k15=(250, 390), k16=(215, 500)),
     [((200, 300), (150, 300))],
     '髋部水平速度 > 1.5 身高/秒；持续 0.6s'),
    ('handup', mk(k7=(175, 95), k8=(245, 95), k9=(160, 40), k10=(260, 40)),
     [], '双手高于肩线且身体近静止；持续 2s'),
    ('photo', mk(k7=(195, 175), k8=(225, 175), k9=(200, 110), k10=(220, 110)),
     [], '双手都在脸高（鼻 ±0.18 身高）、两手相距 < 0.4 身高、'
              '不高于鼻 0.05 身高以上；持续 1.5s'),
    # ---------------- 记录级
    ('squat', mk(k0=(210, 180), k5=(185, 225), k6=(235, 225), k7=(170, 285),
                 k8=(250, 285), k9=(165, 340), k10=(255, 340), k11=(190, 370),
                 k12=(230, 370), k13=(155, 420), k14=(265, 420),
                 k15=(180, 500), k16=(240, 500)),
     [((215, 300), (215, 390))], '髋部接近膝部高度（差 < 0.12 身高）；持续 0.5s'),
]

# 越界动作要画警戒多边形
INTRODE_POLY = [(80, 380), (340, 380), (365, 545), (55, 545)]


def box_of(pts, pad=18):
    xs = [p[0] for p in pts.values()]
    ys = [p[1] for p in pts.values()]
    return (max(0, min(xs) - pad), max(0, min(ys) - pad - 10),
            min(W - 1, max(xs) + pad), min(H - 1, max(ys) + pad))


def render(label, pts, arrows):
    cn, en, color, level = ACTION_META[label]
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = (18, 18, 18)                     # 深灰底，和网页暗色主题一致

    if label == 'intrude':
        poly = np.array(INTRODE_POLY, np.int32)
        overlay = img.copy()
        cv2.fillPoly(overlay, [poly], (0, 60, 120))
        img = cv2.addWeighted(overlay, 0.35, img, 0.65, 0)
        cv2.polylines(img, [poly], True, (0, 165, 255), 2, cv2.LINE_AA)
        cv2.putText(img, 'ZONE', (INTRODE_POLY[0][0] + 6, INTRODE_POLY[0][1] + 22),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 165, 255), 1, cv2.LINE_AA)

    kps = np.zeros((17, 3), np.float32)
    for i, (x, y) in pts.items():
        kps[i] = (x, y, 0.95)

    for a, b in arrows:
        cv2.arrowedLine(img, a, b, (255, 255, 255), 2, cv2.LINE_AA, tipLength=0.25)

    dc.draw_person(img, box_of(pts), 0.90, en, color, 2, kps, show_score=False)
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    rows = []
    for label, pts, arrows, rule in SHEETS:
        img = render(label, pts, arrows)
        fn = '%s.jpg' % label
        cv2.imwrite(os.path.join(OUT, fn), img, [int(cv2.IMWRITE_JPEG_QUALITY), 92])
        cn, en, color, level = ACTION_META[label]
        rows.append((label, cn, en, level, rule, fn))
        print('  %-8s -> %s' % (label, fn))

    md = ['# 危险动作识别 —— 实例骨架图', '',
          '> 由 `rk/ai/convert/gen_action_sheets.py` 生成（绘制走线上的 '
          '`det_core.draw_person`，拓扑与配色和真实画面一致）。',
          '> 图中白色箭头表示**判定所依据的运动方向**。', '',
          '## 总表', '',
          '| 动作 | 中文名 | 英文标签 | 级别 |', '|---|---|---|---|']
    lv = {0: '⚪ 记录', 1: '🟠 提醒', 2: '🔴 报警'}
    for label, cn, en, level, rule, fn in rows:
        md.append('| `%s` | %s | `%s` | %s |' % (label, cn, en, lv.get(level, '?')))
    md.append('')

    for label, cn, en, level, rule, fn in rows:
        md += ['---', '',
               '## %s（`%s`）— %s' % (cn, label, lv.get(level, '?')), '',
               '![%s](action_sheets/%s)' % (en, fn), '',
               '**判定**：%s' % rule, '']

    p = os.path.join(os.path.dirname(OUT), 'ACTIONS.md')
    with open(p, 'w', encoding='utf-8') as f:
        f.write('\n'.join(md))
    print('\n  汇总: %s' % p)
    print('  图片: %s/ (%d 张)' % (OUT, len(rows)))


main()
