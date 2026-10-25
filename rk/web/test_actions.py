#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""动作规则回归测试（合成骨架，不依赖模型/相机）。

用法：/opt/miniforge3/envs/mlk-ov/bin/python test_actions.py

重点护栏：
  * swing 阈值/特征改动后，既要能识别真实挥砍，也不能被走路摆臂、
    双手同挥、单手关键点缺失等场景骗到（这三种是历史误报来源）。
"""
import os
import sys
import math

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
for _p in ('/root/rk/ai/board', os.path.join(_HERE, '..', 'ai', 'board'),
           os.path.join(_HERE, '..', 'board')):
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)
from action_rules import ActionRecognizer  # noqa: E402

BOX = np.array([800, 300, 1100, 900], np.float32)
SIZE = (1920, 1080)          # 画面尺寸：越界判定要把归一化多边形换算成像素
FPS = 30.0

_np_hip_y = 650.0            # base_kps 里的髋高，写测试时方便对照
_np_sh_y = 420.0


def base_kps():
    """直立站立的标准骨架（人框 300x600，站在画面中间）。"""
    k = np.zeros((17, 3), np.float32)
    pts = {0: (950, 330),                     # 鼻
           5: (920, 420), 6: (980, 420),      # 肩
           7: (900, 520), 8: (1000, 520),     # 肘
           9: (880, 640), 10: (1020, 640),    # 腕
           11: (925, 650), 12: (975, 650),    # 髋
           13: (925, 800), 14: (975, 800),    # 膝
           15: (925, 880), 16: (975, 880)}    # 踝
    for i, (x, y) in pts.items():
        k[i] = (x, y, 0.9)
    return k


def run(name, kps_list, expect, zone=None, forbid=()):
    act = ActionRecognizer(alert_polygon=zone)
    got = set()
    t = 0.0
    for kps in kps_list:
        res = act.update(t, [{'tid': 1, 'box': BOX, 'score': 0.9, 'kps': kps}],
                         frame_size=SIZE)
        for a in res[0]['actions']:
            got.add(a['label'])
        t += 1.0 / FPS
    ok = (set(expect) <= got) if expect else (len(got) == 0)
    ok = ok and not (set(forbid) & got)
    print('  %-24s 触发=%-30s 期望=%-18s %s'
          % (name, sorted(got) or ['-'], sorted(expect) or ['(无)'],
             'OK' if ok else '<<< FAIL'))
    return ok


results = []


def _lerp2(a, b, u):
    return (a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u)


def _smooth(u):
    u = 0.0 if u < 0 else (1.0 if u > 1 else u)
    return u * u * (3 - 2 * u)


# ❗ 重要：合成数据必须模拟**前级可观测到**的运动。真实链路是
#   YOLOv8-pose @~30fps + tracker EMA(α=0.55)，等价 ~2.6Hz 低通，
#   腕部峰值速度只有 1~2 身高/秒。旧用例里“每帧瞬移 184px”等于 9 身高/秒，
#   那种信号板上根本采不到，用它标出来的阈值必然失效。
def chop(n=90, ready=(1020, 620), top=(1045, 380), bot=(1005, 600),
         up_f=12, dn_f=9, hold_f=4, period=30):
    """单侧劈砍：举 0.4s → 劈 0.3s → 停 0.13s → 归位（峰值 ≈1.9 身高/秒）。"""
    out = []
    for i in range(n):
        c = i % period
        if c < up_f:
            p = _lerp2(ready, top, _smooth(c / float(up_f)))
        elif c < up_f + dn_f:
            p = _lerp2(top, bot, _smooth((c - up_f) / float(dn_f)))
        elif c < up_f + dn_f + hold_f:
            p = bot
        else:
            rest = period - up_f - dn_f - hold_f
            p = _lerp2(bot, ready, _smooth((c - up_f - dn_f - hold_f) / float(rest)))
        k = base_kps()
        k[10] = (p[0], p[1], 0.9)
        out.append(k)
    return out


# ---- 1. 静止 3 秒：不应有任何动作
results.append(run('静止 3s', [base_kps()] * 90, []))

# ---- 1b. 跌倒/倒地已合并：**静止躺着**（大腿不再下降）也必须报 fall
#       （旧版 lying 是独立类；合并后靠 "躯干>65°" 这半句兜住。
#         如果这里挂了，说明又退回"只认下降速度"，躺着的人永远不会报）
def lying_kps():
    """侧躺：肩中点与髋同高（躯干 90°），髋完全静止。

    ⚠ 所有点都必须落在人体框内 —— `clip_to_box` 会把框外的关节判为无效，
    肩点被清掉后 torso_deg 直接变 None，规则当然不触发（第一版就踩了）。
    """
    k = base_kps()
    k[0] = (1010, 690, 0.9)                       # 鼻
    k[5] = (960, 700, 0.9); k[6] = (1000, 700, 0.9)      # 肩
    k[7] = (930, 700, 0.9); k[8] = (1030, 700, 0.9)      # 肘
    k[9] = (900, 700, 0.9); k[10] = (1060, 700, 0.9)     # 腕
    k[11] = (860, 700, 0.9); k[12] = (900, 700, 0.9)     # 髋
    k[13] = (830, 700, 0.9); k[14] = (840, 710, 0.9)     # 膝
    k[15] = (810, 700, 0.9); k[16] = (820, 700, 0.9)     # 踝
    return k


results.append(run('静止躺地(合并 lying)', [lying_kps()] * 60, ['fall']))

# ---- 2. 挥砍（正例）：单侧劈砍，峰值 ≈1.9 身高/秒（前级真实的量级）
results.append(run('挥砍(单侧劈砍)', chop(90), ['swing']))

# ---- 2b. 挥砍（正例）：幅度小、但更快（峰值 ≈2.2 身高/秒）
results.append(run('挥砍(小幅快劈)',
                   chop(90, top=(1040, 420), bot=(1005, 560), dn_f=5), ['swing']))

# ---- 3. 反例：走路摆臂（正弦、平滑，双手交替，峰值 ≈0.5 身高/秒）
seq = []
for i in range(90):
    k = base_kps()
    s = math.sin(2 * math.pi * 1.6 * i / FPS) * 26.0
    k[9] = (890 - s, 645, 0.9)
    k[10] = (1030 + s, 645, 0.9)
    seq.append(k)
results.append(run('走路摆臂(应不报)', seq, [], forbid=['swing']))

# ---- 4. 反例：双手同时快速挥动（fight 型）—— 单侧性不满足
seq = chop(90)
for i, k in enumerate(seq):
    s = math.sin(2 * math.pi * 2.0 * i / FPS)
    k[9] = (930 - 90 * s, 470 + 90 * s, 0.9)      # 左手镜像同速
results.append(run('双手同挥(应不报挥砍)', seq, [], forbid=['swing']))

# ---- 5. 反例：左手关键点缺失时的快挥（历史误报主因）
#      单侧性会因为 sw_min=0 恒真而失效，规则必须要求两只手都有效。
seq = chop(90)
for k in seq:
    k[9] = (0, 0, 0)
results.append(run('左手缺失快挥(应不报)', seq, [], forbid=['swing']))

# ---- 6. 投掷：双手抬起，右腕从下往上快速上撩并过肩
seq = []
for i in range(20):
    k = base_kps()
    if i < 6:
        k[9] = (900, 640, 0.9)
        k[10] = (1020, 700, 0.9)
    else:
        k[9] = (900, 380, 0.9)
        k[10] = (1030, 380, 0.9)
    seq.append(k)
results.append(run('投掷(上撩过肩)', seq, ['throw']))

# ---- 7. 拍照：双手举到脸高附近、彼此靠拢、保持 2 秒
k = base_kps()
k[9] = (930, 340, 0.9)
k[10] = (975, 340, 0.9)
results.append(run('拍照(双手捧到脸前)', [k] * 60, ['photo']))

# ---- 7b/7c 反例：双手分开 / 单手抬起，不得到拍照
k = base_kps()
k[9] = (820, 340, 0.9)
k[10] = (1080, 340, 0.9)
results.append(run('非拍照(双手分开)', [k] * 60, [], forbid=['photo']))

k = base_kps()
k[9] = (935, 350, 0.9)
k[10] = (1020, 640, 0.9)
results.append(run('非拍照(单手抬到脸前)', [k] * 60, [], forbid=['photo']))

# ---- 8. 举手求救：双手高举过头
k = base_kps()
k[9] = (930, 250, 0.9)
k[10] = (975, 250, 0.9)
results.append(run('举手求救(高举过头)', [k] * 80, ['handup'], forbid=['swing']))

# ---- 9. 越界：脚点落在警戒多边里（zone 用归一化坐标，与 --ai-zone 一致）
ZONE = [(0.3, 0.6), (0.7, 0.6), (0.7, 0.95), (0.3, 0.95)]
results.append(run('越界(脚在多边形内)', [base_kps()] * 30, ['intrude'], zone=ZONE))
results.append(run('不越界(多边形在别处)', [base_kps()] * 30, [],
                   zone=[(0.05, 0.05), (0.25, 0.05), (0.25, 0.25), (0.05, 0.25)]))

print('-' * 70)
print('  %d/%d 通过' % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
