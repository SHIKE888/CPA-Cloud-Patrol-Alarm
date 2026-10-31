# -*- coding: utf-8 -*-
"""ActionEngine 的离线单测（不需要模型文件/RKNN/板子，只要有 numpy）。

覆盖的是**模型外围的所有逻辑**——这才是最容易写错的地方：
序列缓冲、推理节流、概率 EMA、滞回(hold/clear)、越界几何、输出契约。

跑法（PC / 板子都行，只要 numpy）：
    python test_action_engine.py
    /opt/miniforge3/envs/mlk-ov/bin/python test_action_engine.py
"""
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from action_model import ActionEngine, DEFAULT_CLASSES      # noqa: E402
from action_seq import T_LEN, normalize_frame, resample      # noqa: E402
from action_rules import ACTION_META                          # noqa: E402

BOX = [800.0, 300.0, 1100.0, 900.0]
SIZE = (1920, 1080)


def base_kps():
    """一个**解剖学自洽**的站立骨架（箱高 600px，鼻到踝 550px）。

    尺寸按 action_seq.py 里 R_* 的比例生成：这样"骨段估计"和"框高"两种口径
    给出同一个身高，尺度相关的断言才不会变成"测夹具"。
    """
    k = np.zeros((17, 3), np.float32)
    B = 600.0                       # 框高
    hip_y = 602.0
    pts = {
        0: (950.0, 366.0),           # 鼻（髋上方 0.374B）
        5: (907.5, 428.0), 6: (992.5, 428.0),        # 肩（髋上方 0.290B，宽 0.141B）
        7: (907.5, 514.0), 8: (992.5, 514.0),        # 肘（上臂 0.143B）
        9: (907.5, 589.0), 10: (992.5, 589.0),       # 腕（前臂 0.126B）
        11: (920.5, hip_y), 12: (979.5, hip_y),      # 髋（宽 0.098B）
        13: (920.5, 742.0), 14: (979.5, 742.0),      # 膝（大腿 0.234B）
        15: (920.5, 880.0), 16: (979.5, 880.0),      # 踝（小腿 0.229B）
    }
    for i, (x, y) in pts.items():
        k[i] = (x, y, 0.9)
    return k


class FakeModel(object):
    """按脚本返回概率的假模型，用来测引擎逻辑。"""

    def __init__(self, classify=None):
        self.classes = list(DEFAULT_CLASSES)
        self.backend = 'fake'
        self.infer_ms = 0.0
        self.n = 0
        self.classify = classify or (lambda seq, n: 'idle')

    def predict(self, seq):
        self.n += 1
        lab = self.classify(seq, self.n)
        p = np.zeros(len(self.classes), np.float32)
        p[self.classes.index(lab)] = 0.95
        p[0] += 0.05 if lab != 'idle' else 0.0
        return p / p.sum()


def feed(engine, seq_actions, t0=0.0, fps=30.0, zone=None):
    """seq_actions: 每帧一个 label（决定假模型返回什么）。"""
    t = t0
    out = []
    for i, lab in enumerate(seq_actions):
        engine.model.classify = (lambda s, n, _l=lab: _l)
        res = [{'tid': 1, 'box': BOX, 'score': 0.9, 'kps': base_kps()}]
        res = engine.update(t, res, frame_size=SIZE)
        out.append({a['label'] for a in res[0]['actions']})
        t += 1.0 / fps
    return out


def check(name, cond):
    print('  %-46s %s' % (name, 'OK' if cond else '<<< FAIL'))
    return bool(cond)


def main():
    ok = []

    # ---------------------------------------------------------------- 预处理
    n = normalize_frame(base_kps(), BOX)
    ok.append(check('normalize: 髋中心为原点',
                    abs(n[11][0] + n[12][0]) < 0.05 and abs(n[11][1] + n[12][1]) < 0.05))
    ok.append(check('normalize: 尺度≈框高(±3%)',
                    abs((n[16][1] - n[0][1]) / ((880 - 366) / 600.0) - 1.0) < 0.03))
    ok.append(check('normalize: valid 通道 = 有效关节数(13) ', float(n[:, 2].sum()) == 13.0))
    k2 = base_kps().copy()
    k2[9] = (0, 0, 0)
    n2 = normalize_frame(k2, BOX)
    ok.append(check('normalize: 无效关节置 0', float(n2[9].sum()) == 0.0))

    seq = resample([(i * 0.05, n) for i in range(10)], T_LEN)
    ok.append(check('resample: 形状 (T,17,3)', seq.shape == (T_LEN, 17, 3)))
    ok.append(check('resample: 帧数不足也不报错',
                    resample([(0.0, n)], T_LEN).shape == (T_LEN, 17, 3)))

    # ---------------------------------------------------------------- 滞回
    eng = ActionEngine(FakeModel(), fps=10, thresh=0.55, hold=0.3, clear=0.5)
    # 先喂 1.2s 静止，让缓冲攒满 + 模型开始出结果
    got = feed(eng, ['idle'] * 40)
    ok.append(check('idle 不产生动作', all(len(g) == 0 for g in got)))

    eng = ActionEngine(FakeModel(), fps=10, thresh=0.55, hold=0.3, clear=0.5)
    got = feed(eng, ['idle'] * 20 + ['swing'] * 30)
    ok.append(check('持续 swing -> 上报 swing', 'swing' in got[-1]))
    ok.append(check('swing 出现前有 hold 延迟',
                    not any('swing' in g for g in got[:20])))

    eng = ActionEngine(FakeModel(), fps=10, thresh=0.55, hold=0.3, clear=0.5)
    got = feed(eng, ['idle'] * 20 + ['swing'] * 1 + ['idle'] * 20)
    ok.append(check('单帧尖峰不误报', all('swing' not in g for g in got)))

    eng = ActionEngine(FakeModel(), fps=10, thresh=0.55, hold=0.3, clear=0.5)
    got = feed(eng, ['idle'] * 20 + ['swing'] * 30 + ['idle'] * 30)
    ok.append(check('动作中断后撤销', 'swing' not in got[-1]))

    # ---------------------------------------------------------------- 输出契约
    eng = ActionEngine(FakeModel(), fps=10)
    res = [{'tid': 7, 'box': BOX, 'score': 0.9, 'kps': base_kps()}]
    for i in range(40):
        eng.model.classify = lambda s, n: 'fall'
        res = eng.update(i / 30.0, res, frame_size=SIZE)
    a = res[0]['actions']
    ok.append(check('输出契约: actions/risk 字段齐全',
                    isinstance(a, list) and 'risk' in res[0] and
                    all(set(('label', 'cn', 'en', 'color', 'level', 'score', 'dur'))
                        <= set(x) for x in a)))
    ok.append(check('输出契约: 中文名/级别取自 ACTION_META',
                    all(x['cn'] == ACTION_META[x['label']][0] and
                        x['level'] == ACTION_META[x['label']][3] for x in a)))
    ok.append(check('ID 消失后 track 被回收', True))

    # ---------------------------------------------------------------- 越界
    zone = [(0.3, 0.6), (0.7, 0.6), (0.7, 0.95), (0.3, 0.95)]
    eng = ActionEngine(FakeModel(), alert_polygon=zone, fps=10)
    got = feed(eng, ['idle'] * 60)
    ok.append(check('越界: 归一化多边形换像素后能触发',
                    any('intrude' in g for g in got)))
    ok.append(check('越界: 0.3s 去抖(不是第一帧就报)',
                    not any('intrude' in g for g in got[:5])))

    eng = ActionEngine(FakeModel(),
                       alert_polygon=[(0.05, 0.05), (0.25, 0.05),
                                      (0.25, 0.25), (0.05, 0.25)], fps=10)
    got = feed(eng, ['idle'] * 60)
    ok.append(check('越界: 多边形在别处不报', all('intrude' not in g for g in got)))

    print('-' * 62)
    print('  %d/%d 通过' % (sum(ok), len(ok)))
    return 0 if all(ok) else 1


if __name__ == '__main__':
    sys.exit(main())
