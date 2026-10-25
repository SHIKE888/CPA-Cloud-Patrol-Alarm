# -*- coding: utf-8 -*-
"""JHMDB（DD-Net 整理版）→ 我们格式的训练样本。

数据源
------
`https://raw.githubusercontent.com/fandulu/DD-Net/master/data/JHMDB/joint_positions.zip`
(13.5 MB，21 类 / ~900 段视频的 2D 关节，**不需要注册**)
结构：`joint_positions/<action>/<clip>/joint_positions.mat`
  pos_img  (2, 15, T)  x,y 像素
  scale    (T,)        人体尺度（JHMDB 官方标注，≈ 人体高度的像素值 / 240）
  viewpoint

15 关节顺序（JHMDB 官方） → COCO-17
------------------------------------
  0 rankle  1 rknee  2 rhip   3 lhip   4 lknee   5 lankle
  6 rwrist  7 relbow 8 rshoulder 9 lshoulder 10 lelbow 11 lwrist
  12 neck   13 head  14 htop

⚠ 13/15 关节里没有五官：鼻子用 head 近似，眼睛/耳朵按头部比例**合成**。
  不要把它们留成 valid=0 —— 真实推理时五官几乎总是有效，留空会让模型
  学到“五官无效=某个动作”的伪特征。

用法
----
    python extract_jhmdb.py --src D:\\datasets\\JHMDB\\jp --out D:\\datasets\\action_data
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
from scipy.io import loadmat

_HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join(_HERE, '..', 'board'), _HERE):
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)

from action_seq import T_LEN, normalize_frame, resample      # noqa: E402

# JHMDB 动作 → 我们的标签；None = 用不上
JHMDB_MAP = {
    'swing_baseball': 'swing',
    'golf': 'swing',
    'throw': 'throw',
    'run': 'run',
    'wave': 'handup',
    'climb_stairs': 'climb',
    'walk': 'idle',
    'stand': 'idle',
    # 这些“日常但不是我们目标”的动作 → idle：它们是误报的主要来源，
    # 正是需要的**难负样本**（模型学会它们不是告警）。
    'pick': 'idle',      # 弯腰执东西
    'pour': 'idle',
    'clap': 'idle',
    'brush_hair': 'idle',
    'catch': 'idle',
    'jump': 'idle',
    # ❗ sit 故意不放进去：坐下和下蹲形态接近，标成 idle 会抵消 squat
    'sit': None, 'kick_ball': None,
    # pullup 像攀爬、push 像冲突，也不能当 idle
    'pullup': None, 'push': None,
    'shoot_ball': None, 'shoot_bow': None, 'shoot_gun': None,
}

# JHMDB 15 关节索引
RA, RK, RH, LH, LK, LA = 0, 1, 2, 3, 4, 5
RW, RE, RS, LS, LE, LW = 6, 7, 8, 9, 10, 11
NECK, HEAD, HTOP = 12, 13, 14

# COCO-17 索引
C_NOSE = 0
C_EYE_L, C_EYE_R, C_EAR_L, C_EAR_R = 1, 2, 3, 4
C_SH_L, C_SH_R = 5, 6
C_EL_L, C_EL_R = 7, 8
C_WR_L, C_WR_R = 9, 10
C_HIP_L, C_HIP_R = 11, 12
C_KN_L, C_KN_R = 13, 14
C_AN_L, C_AN_R = 15, 16

# (coco_idx, jhmdb_idx)
DIRECT = [
    (C_NOSE, HEAD),
    (C_SH_L, LS), (C_SH_R, RS),
    (C_EL_L, LE), (C_EL_R, RE),
    (C_WR_L, LW), (C_WR_R, RW),
    (C_HIP_L, LH), (C_HIP_R, RH),
    (C_KN_L, LK), (C_KN_R, RK),
    (C_AN_L, LA), (C_AN_R, RA),
]


def to_coco17(pos, scale_px):
    """pos (2,15) 像素 + 人体高度 -> (17,3) 像素 + 置信度。"""
    x, y = pos[0], pos[1]
    k = np.zeros((17, 3), np.float32)
    for c, j in DIRECT:
        k[c, 0] = x[j]
        k[c, 1] = y[j]
        k[c, 2] = 1.0
    # 五官：按人头比例合成（相对 head/nose）
    nx, ny = k[C_NOSE, 0], k[C_NOSE, 1]
    dx = 0.035 * scale_px      # 眼间距 / 耳间距的粗略比例
    dy = 0.02 * scale_px
    k[C_EYE_L] = (nx - dx, ny - dy * 0.5, 1.0)
    k[C_EYE_R] = (nx + dx, ny - dy * 0.5, 1.0)
    k[C_EAR_L] = (nx - dx * 1.8, ny, 1.0)
    k[C_EAR_R] = (nx + dx * 1.8, ny, 1.0)
    return k


def box_from_kps(k):
    """用人体现有 17 点求框（与检测框高度尽量接近）。"""
    v = k[:, 2] > 0
    x1, x2 = float(k[v, 0].min()), float(k[v, 0].max())
    y1, y2 = float(k[v, 1].min()), float(k[v, 1].max())
    h = y2 - y1
    # 关节跨度 ≈ 框高的 0.93（踝到头顶），补一点余量对齐检测框
    bh = h / 0.93
    pad = (bh - h) * 0.5
    return np.array([x1 - pad * 0.6, y1 - pad, x2 + pad * 0.6, y2 + pad * 1.6],
                    np.float32)


def convert_clip(mat_path, label, stride, max_per_clip, min_kpt, max_jump=1.5):
    m = loadmat(mat_path, squeeze_me=True)
    pos = np.asarray(m['pos_img'], np.float64)          # (2,15,T)
    if pos.ndim != 3 or pos.shape[0] != 2:
        return []
    n = pos.shape[2]
    sc = np.asarray(m.get('scale', np.ones(n)), np.float64).reshape(-1)
    if sc.size != n:
        sc = np.full(n, float(sc.reshape(-1)[0]) if sc.size else 0.3)
    # JHMDB 的 scale ≈ 人体高度 / 240（图像高 240）
    scale_px = sc * 240.0

    frames = []
    for i in range(n):
        if not np.isfinite(pos[0, :, i]).all():
            continue
        k = to_coco17(pos[:, :, i], scale_px[i])
        frames.append((i / 30.0, k, box_from_kps(k)))
    if len(frames) < T_LEN:
        return []

    out = []
    for s in range(0, len(frames) - T_LEN + 1, max(1, stride)):
        seg = frames[s:s + T_LEN]
        if np.mean([(f[1][:, 2] > 0).sum() for f in seg]) < min_kpt:
            continue
        if max_jump and max_jump > 0:
            jm = 0.0
            for a, b in zip(seg[:-1], seg[1:]):
                bh = max(1.0, float(a[2][3] - a[2][1]))
                d = np.hypot(b[1][:, 0] - a[1][:, 0], b[1][:, 1] - a[1][:, 1]) / bh
                jm = max(jm, float(d.max()))
            if jm > max_jump:
                continue
        norm = [(f[0], normalize_frame(f[1], f[2])) for f in seg]
        out.append(resample(norm, T_LEN))
        if max_per_clip and len(out) >= max_per_clip:
            break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default=r'D:\datasets\JHMDB\jp')
    ap.add_argument('--out', default=r'D:\datasets\action_data')
    ap.add_argument('--stride', type=int, default=4)
    ap.add_argument('--max-per-clip', type=int, default=8)
    ap.add_argument('--min-kpt', type=int, default=15)
    ap.add_argument('--max-jump', type=float, default=1.5)
    args = ap.parse_args()

    root = os.path.join(args.src, 'joint_positions')
    if not os.path.isdir(root):
        root = args.src
    total, skipped = {}, {}
    for action in sorted(os.listdir(root)):
        d = os.path.join(root, action)
        if not os.path.isdir(d) or action.startswith('.'):
            continue
        label = JHMDB_MAP.get(action)
        if label is None:
            continue
        clips = sorted(glob.glob(os.path.join(d, '*', 'joint_positions.mat')))
        for ci, mp in enumerate(clips):
            tag = '%s_%s_%03d' % (label, action, ci)
            samples = convert_clip(mp, label, args.stride,
                                   args.max_per_clip, args.min_kpt, args.max_jump)
            if not samples:
                skipped[action] = skipped.get(action, 0) + 1
                continue
            od = os.path.join(args.out, label)
            os.makedirs(od, exist_ok=True)
            for i, seq in enumerate(samples):
                np.savez(os.path.join(od, '%s_%d.npz' % (tag, i)),
                         seq=seq.astype(np.float32), label=np.array(label))
            total[label] = total.get(label, 0) + len(samples)
        print('  %-16s -> %-8s clips=%d  samples=%d'
              % (action, label, len(clips), total.get(label, 0)), flush=True)

    print('-' * 60)
    for k in sorted(total):
        print('  %-8s %5d 段' % (k, total[k]))
    print('  合计     %5d 段' % sum(total.values()))
    if skipped:
        print('  跳过的 clip:', skipped)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'extract_jhmdb.json'), 'w',
              encoding='utf-8') as fp:
        json.dump(total, fp, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
