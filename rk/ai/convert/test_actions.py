#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_actions.py —— 用**合成骨架**回归测试动作规则（不需要摄像头、不碰 NPU）。

用途：新增/调整动作规则时先跑这个，确认
  ① 静止时不会误报；
  ② 每个动作在典型姿态下能被触发。

用法: python test_actions.py
"""
from __future__ import annotations

import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
# 这个脚本在仓库里放在 convert/ 下，但板上 convert/ 不存在（只有 board/ 和 models/），
# 所以三个候选路径都试一遍，放哪都能跑。
for _p in (os.path.join(_HERE, '..', 'board'), _HERE, '/root/rk/ai/board'):
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)
from action_rules import ActionRecognizer  # noqa: E402

BOX = np.array([800, 300, 1100, 900], np.float32)
BH = 600.0          # 人体框高（归一化基准）


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


def frames(kps_list):
    return kps_list


def run(name, kps_list, expect):
    act = ActionRecognizer()
    got = set()
    t = 0.0
    for kps in kps_list:
        res = act.update(t, [{'tid': 1, 'box': BOX, 'score': 0.9, 'kps': kps}])
        for a in res[0]['actions']:
            got.add(a['label'])
        t += 1 / 30.0
    ok = (set(expect) <= got) if expect else (len(got) == 0)
    print('  %-20s 触发=%-26s 期望=%-16s %s'
          % (name, sorted(got) or ['-'], sorted(expect) or ['(无)'],
             'OK' if ok else '<<< FAIL'))
    return ok


results = []

# ---- 1. 静止 3 秒：不应有任何动作
results.append(run('静止 3s', [base_kps()] * 90, []))

# ---- 2. 挥砍：右手大幅摆动（8 帧一往复 ≈ 0.27s，位移约 0.6 身高），左手不动
seq = []
for i in range(24):
    k = base_kps()
    k[10] = (1080, 340, 0.9) if (i // 4) % 2 == 0 else (1000, 700, 0.9)
    seq.append(k)
results.append(run('挥砍(单侧快挥)', seq, ['swing']))

# ---- 3. 投掷：双手抬起，右腕从下往上快速上撩并过肩（之后保持过肩）
seq = []
for i in range(20):
    k = base_kps()
    if i < 6:
        k[9] = (900, 640, 0.9)          # 左手在低位
        k[10] = (1020, 700, 0.9)        # 右手在低位
    else:
        k[9] = (900, 380, 0.9)          # 双手都过肩
        k[10] = (1030, 380, 0.9)
    seq.append(k)
results.append(run('投掷(上撩过肩)', seq, ['throw']))

# ---- 4. 拍照：双手举到脸高附近、彼此靠近、保持 2 秒
k = base_kps()
k[9] = (930, 340, 0.9)
k[10] = (975, 340, 0.9)
results.append(run('拍照(双手捧到脸前)', [k] * 60, ['photo']))

# ---- 5. 举手求救：双手高举过头（应在 photo 之上，不误判成拍照）
k = base_kps()
k[9] = (860, 250, 0.9)
k[10] = (1040, 250, 0.9)
results.append(run('举手求救(高举过头)', [k] * 80, ['handup']))

print('-' * 70)
print('  %d/%d 通过' % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
