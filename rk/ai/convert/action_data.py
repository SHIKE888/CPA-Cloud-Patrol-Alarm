# -*- coding: utf-8 -*-
"""数据加载 / 合成 / 增强（纯 numpy，torch 与 tf 两条训练路径共用）。"""
import glob
import os

import numpy as np

from action_spec import ACTION_CLASSES, T_LEN, V_JOINTS, C_CH, MIRROR_IDX


def load_dataset(data_dir, verbose=True):
    """返回 X (N,T,17,3) float32, y (N,) int64。读 record_action.py 的产物。"""
    files = sorted(glob.glob(os.path.join(data_dir, '**', '*.npz'), recursive=True))
    if not files:
        raise SystemExit('在 %s 下没找到 *.npz' % data_dir)
    xs, ys, skipped = [], [], 0
    for fp in files:
        try:
            z = np.load(fp, allow_pickle=True)
            seq = np.asarray(z['seq'], np.float32)
            lab = z['label']
            lab = str(lab.item()) if hasattr(lab, 'item') else str(lab)
        except Exception as e:                            # noqa: BLE001
            if verbose:
                print('[skip] %s: %s' % (fp, e))
            skipped += 1
            continue
        if lab not in ACTION_CLASSES:
            if verbose:
                print('[skip] %s: 未知标签 %r' % (fp, lab))
            skipped += 1
            continue
        if seq.shape != (T_LEN, V_JOINTS, C_CH):
            if verbose:
                print('[skip] %s: 形状 %s' % (fp, seq.shape))
            skipped += 1
            continue
        xs.append(seq)
        ys.append(ACTION_CLASSES.index(lab))
    if not xs:
        raise SystemExit('没有可用样本')
    if verbose:
        print('载入 %d 段 (%d 个文件被跳过)' % (len(xs), skipped))
    return np.stack(xs), np.asarray(ys, np.int64)


def make_synthetic(n_per_class=120, seed=0):
    """纯随机骨架序列 —— 只用来验证训练/导出链路，不要拿它当模型用。"""
    rng = np.random.RandomState(seed)
    xs, ys = [], []
    for ci in range(len(ACTION_CLASSES)):
        for _ in range(n_per_class):
            base = rng.randn(V_JOINTS, C_CH).astype(np.float32) * 0.15
            base[:, 2] = 1.0
            amp = 0.02 + 0.10 * (ci % 4)
            freq = 1.0 + 0.7 * (ci % 5)
            t = np.arange(T_LEN, dtype=np.float32) / float(T_LEN)
            osc = np.sin(2 * np.pi * freq * t) * amp
            seq = np.repeat(base[None], T_LEN, 0)
            seq[:, :, 0] += osc[:, None] * (1.0 if ci % 2 else -1.0)
            seq += rng.randn(*seq.shape).astype(np.float32) * 0.01
            xs.append(seq)
            ys.append(ci)
    return np.stack(xs), np.asarray(ys, np.int64)


def augment(seq, rng, strength=1.0):
    """镜像 / 倒放 / 速度扰动 / 缩放平移 / 噪声。

    镜像是最有效的一条：挥砍、投掷、拍照都可能是任意一只手。
    """
    # 1) 左右镜像
    if rng.rand() < 0.5:
        seq = seq[:, MIRROR_IDX, :].copy()
        seq[:, :, 0] *= -1.0
    # 2) 时间反向（动作倒放仍是同一类，但能防止模型吃"方向"捷径）
    if rng.rand() < 0.2:
        seq = seq[::-1].copy()
    # 3) 速度扰动 0.8~1.25 倍
    sp = 1.0 + (rng.rand() - 0.5) * 0.5
    if abs(sp - 1.0) > 0.03:
        n = seq.shape[0]
        grid = np.clip(np.linspace(0, n - 1, n) * sp, 0, n - 1)
        src = np.arange(n, dtype=np.float64)
        out = np.empty_like(seq)
        for v in range(seq.shape[1]):
            for c in range(seq.shape[2]):
                out[:, v, c] = np.interp(grid, src, seq[:, v, c])
        seq = out
    # 4) 整体缩放 / 平移 / 噪声（注意是 (T,V,C) 三维，平移只改前两维 x,y）
    seq = seq * (1.0 + (rng.rand() - 0.5) * 0.2 * strength)
    shift = (rng.rand(1, 1, 2).astype(np.float32) - 0.5) * 0.06 * strength
    seq[:, :, :2] += shift
    seq = seq + rng.randn(*seq.shape).astype(np.float32) * 0.01 * strength
    return seq.astype(np.float32)


def split_stratified(y, val=0.15, seed=0):
    """分层切分，返回 (tr_idx, va_idx)。"""
    rng = np.random.RandomState(seed)
    tr, va = [], []
    for c in range(len(ACTION_CLASSES)):
        idx = np.where(y == c)[0]
        rng.shuffle(idx)
        k = max(1, int(len(idx) * val)) if len(idx) > 4 else 0
        va.extend(idx[:k])
        tr.extend(idx[k:])
    tr = np.asarray(tr, np.int64)
    va = np.asarray(va, np.int64)
    if len(va) == 0:
        va = tr[:max(1, len(tr) // 10)]
    return tr, va


def class_weights(y, idx):
    """类别频率反比加权（idle 往往占一半）。"""
    cnt = np.bincount(y[idx], minlength=len(ACTION_CLASSES)).astype(np.float64)
    cnt[cnt == 0] = 1.0
    w = (cnt.sum() / cnt) ** 0.5
    return (w / w.mean()).astype(np.float32)
