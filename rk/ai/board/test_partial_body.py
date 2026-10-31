# -*- coding: utf-8 -*-
"""肢体不完整（人被画面切掉一半）时的归一化稳定性测试。

背景
----
原来是 `bh = 检测框高`。人只露出上半身时框高只剩真实身高的一半 →
所有归一化位移翻倍 → 速度阈值（swing 1.0 / run 0.9 身高每秒）全部失准，
站着不动也会被判成挥砍/奔跑。

现在改成：**用可见骨段长度 / 人体比例估计身高**（骨长是刚性的，与动作无关），
完整可见时才以框高为主；原点在完整时取髋中点，不能全包时**优先锁头**反推。

本测试把同一段动作放到三种取景里跑（全身 / 腿被切 / 头被切），比较：
  * 估计身高 / 真实身高
  * 腕部峰值速度（这个量直接决定 swing/throw/run 的门限）
  * 分类结果

    python test_partial_body.py
"""
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from action_seq import SeqBuffer, estimate_body, normalize_frame   # noqa: E402
from action_demo_cls import features, classify, CLASSES            # noqa: E402

# 站立基准（单位=身高，原点=髋中点，y 向下）
BASE = [(0.000, -0.440), (-0.030, -0.455), (0.030, -0.455), (-0.060, -0.440),
        (0.060, -0.440), (-0.100, -0.350), (0.100, -0.350), (-0.130, -0.200),
        (0.130, -0.200), (-0.140, -0.080), (0.140, -0.080), (-0.055, 0.000),
        (0.055, 0.000), (-0.060, 0.260), (0.060, 0.260), (-0.060, 0.500),
        (0.060, 0.500)]

W, H = 1920, 1080
BH_PX = 700.0          # 真实身高（像素）


def pose_at(t, kind='idle'):
    """生成一帧姿态（单位=身高，原点=髋中点）。"""
    p = np.array(BASE, np.float32)
    br = 0.006 * np.sin(t * 2 * np.pi * 0.28)          # 呼吸
    p[:, 1] += br
    if kind == 'swing':                                 # 单侧快劈
        c = t % 1.15
        if c < 0.42:
            u = c / 0.42
        elif c < 0.72:
            u = 1.0 - (c - 0.42) / 0.30
        elif c < 0.82:
            u = 0.0
        else:
            u = 0.0
        u = u * u * (3 - 2 * u)
        p[10] = [-0.140 + 0.290 * u, -0.080 - 0.520 * u]      # 右手抬到头顶
        p[8] = [0.060 + 0.100 * u, -0.200 - 0.130 * u]
    elif kind == 'squat':
        c = t % 2.2
        k = (c / 0.6) if c < 0.6 else (1.0 if c < 1.8 else 1 - (c - 1.8) / 0.4)
        k = min(1.0, max(0.0, k))
        p[13, 0] = -0.060 - 0.030 * k
        p[14, 0] = 0.060 + 0.030 * k
        p[15, 1] = 0.500 - 0.150 * k
        p[16, 1] = 0.500 - 0.150 * k
    return p


def make_case(kind, hip_y, n=40, fps=30.0):
    """返回 [(t, kps_px(17,3), box, frame_size)]，模拟检测器输出。"""
    out = []
    for i in range(n):
        t = i / fps
        pose = pose_at(t, kind)
        k = np.zeros((17, 3), np.float32)
        for j in range(17):
            px = W * 0.5 + pose[j, 0] * BH_PX
            py = hip_y + pose[j, 1] * BH_PX
            inside = (0 <= px < W) and (0 <= py < H)      # 出画面 = 无效
            k[j] = (px, py, 1.0 if inside else 0.0)
        v = k[:, 2] > 0
        if not v.any():
            continue
        box = (float(k[v, 0].min()), float(k[v, 1].min()),
               float(k[v, 0].max()), float(k[v, 1].max()))
        out.append((t, k, box, (W, H)))
    return out


def run(cases, tag, old=False):
    buf = SeqBuffer(maxlen=120)
    for t, k, box, fs in cases:
        if old:
            # 改动前的行为：bh = 框高，原点=髋中点（无效则框中心）
            out = np.zeros((17, 3), np.float32)
            bh = max(1.0, box[3] - box[1])
            if k[11, 2] > 0 and k[12, 2] > 0:
                cx = (k[11, 0] + k[12, 0]) * 0.5
                cy = (k[11, 1] + k[12, 1]) * 0.5
            else:
                cx, cy = (box[0] + box[2]) * 0.5, (box[1] + box[3]) * 0.5
            for j in range(17):
                if k[j, 2] > 0:
                    out[j] = ((k[j, 0] - cx) / bh, (k[j, 1] - cy) / bh, 1.0)
            buf.frames.append((t, out))
        else:
            buf.push(t, k, box, fs)
    seq = buf.build(32)
    f = features(seq)
    p = classify(f)
    top = CLASSES[int(p.argmax())]
    return dict(scale=(buf.scale or 0.0) / BH_PX, wrMax=f['wrMax'],
                wrMin=f['wrMin'], top=top, prob=float(p.max()),
                torso=f['torso'], info=getattr(buf, 'info', ''))


def main():
    scenarios = [('全身', 520.0), ('腿被切(下边缘)', 800.0), ('头被切(上边缘)', 320.0)]
    for old in (True, False):
        print('\n%s' % ('===== 改动前：bh = 检测框高 =====' if old
                        else '===== 改动后：骨段比例 + 锁头/髋中心 ====='))
        print('%-14s %-7s %-9s %-9s %-8s %-9s' %
              ('取景', '动作', '估计身高', '腕峰值速度', '判定', '置信'))
        for kind in ('idle', 'swing', 'squat'):
            for name, hipy in scenarios:
                r = run(make_case(kind, hipy), name, old=old)
                print('%-14s %-7s %7.2f× %8.2f  %-8s %6.2f'
                      % (name, kind, r['scale'], r['wrMax'], r['top'], r['prob']))
            print()


if __name__ == '__main__':
    main()
