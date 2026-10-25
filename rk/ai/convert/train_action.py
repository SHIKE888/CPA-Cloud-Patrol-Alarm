# -*- coding: utf-8 -*-
"""训练轻量骨架动作模型（在 VM 上跑，不需要板子）。

数据准备
--------
1. 板上采集（板子在线时）：
       /opt/miniforge3/envs/mlk-ov/bin/python /root/rk/web/record_action.py \
           --label swing --seconds 60 --out /root/rk/ai/data
   每个动作采 60~120 段（每段 1 秒左右，互相重叠无所谓），共 11 类，
   **idle（无动作）一定要多采**，而且要包含走路、弯腰捡东西、说话挥手、
   双手插兜、整理头发这类"日常小动作"——它们就是误报的来源。
2. 拉回本地/VM：`scp -r afc03:/root/rk/ai/data ./data`

训练
----
    python train_action.py --data ./data --epochs 80 --out action_net.pt
    python train_action.py --synthetic              # 不接数据，验证流程能跑通

产出 `action_net.pt`（含 state_dict + classes），再走
export_action_onnx.py -> convert_action_rknn.py。
"""
import argparse
import glob
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

import torch                                              # noqa: E402
import torch.nn as nn                                     # noqa: E402
from torch.utils.data import Dataset, DataLoader          # noqa: E402

from action_net import (ACTION_CLASSES, T_LEN, C_CH, V_JOINTS,  # noqa: E402
                        MIRROR_IDX, ActionNet)


# ---------------------------------------------------------------- 数据

def load_dataset(data_dir):
    """返回 X (N,T,17,3) float32, y (N,) int64。"""
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
            print('[skip] %s: %s' % (fp, e))
            skipped += 1
            continue
        if lab not in ACTION_CLASSES:
            print('[skip] %s: 未知标签 %r' % (fp, lab))
            skipped += 1
            continue
        if seq.shape != (T_LEN, V_JOINTS, C_CH):
            print('[skip] %s: 形状 %s' % (fp, seq.shape))
            skipped += 1
            continue
        xs.append(seq)
        ys.append(ACTION_CLASSES.index(lab))
    if not xs:
        raise SystemExit('没有可用样本')
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


class SeqDataset(Dataset):
    def __init__(self, X, y, train=True, aug=1.0):
        self.X, self.y, self.train, self.aug = X, y, train, float(aug)

    def __len__(self):
        return len(self.y)

    def _augment(self, seq):
        rng = np.random
        # 1) 左右镜像（最有效的一条：挥砍/投掷/拍照都可能是任意手）
        if rng.rand() < 0.5:
            seq = seq[:, MIRROR_IDX, :].copy()
            seq[:, :, 0] *= -1.0
        # 2) 时间反向（动作倒放仍是同一类，但能让模型不吃"方向"捷径）
        if rng.rand() < 0.2:
            seq = seq[::-1].copy()
        # 3) 速度扰动 0.8~1.25 倍
        sp = 1.0 + (rng.rand() - 0.5) * 0.5
        if abs(sp - 1.0) > 0.03:
            n = seq.shape[0]
            grid = np.linspace(0, n - 1, n) * sp
            grid = np.clip(grid, 0, n - 1)
            out = np.empty_like(seq)
            src = np.arange(n)
            for c in range(seq.shape[2]):
                for v in range(seq.shape[1]):
                    out[:, v, c] = np.interp(grid, src, seq[:, v, c])
            seq = out
        # 4) 整体缩放 / 平移 / 噪声
        seq = seq * (1.0 + (rng.rand() - 0.5) * 0.2 * self.aug)
        seq = seq + (rng.rand(1, 1, 2).astype(np.float32) - 0.5) * 0.06 * self.aug
        seq = seq + rng.randn(*seq.shape).astype(np.float32) * 0.01 * self.aug
        return seq.astype(np.float32)

    def __getitem__(self, i):
        seq = self.X[i]
        if self.train:
            seq = self._augment(seq)
        return torch.from_numpy(seq), int(self.y[i])


# ---------------------------------------------------------------- 训练

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default='', help='npz 目录')
    ap.add_argument('--synthetic', action='store_true', help='不接真实数据，只跑通链路')
    ap.add_argument('--epochs', type=int, default=80)
    ap.add_argument('--batch', type=int, default=64)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--wd', type=float, default=1e-2)
    ap.add_argument('--val', type=float, default=0.15, help='验证集比例')
    ap.add_argument('--aug', type=float, default=1.0, help='增强强度 0~1.5')
    ap.add_argument('--out', default='action_net.pt')
    ap.add_argument('--seed', type=int, default=0)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    if args.synthetic or not args.data:
        if not args.synthetic:
            print('未给 --data，自动进入 --synthetic 模式')
        X, y = make_synthetic()
    else:
        X, y = load_dataset(args.data)

    # 分层切分
    rng = np.random.RandomState(args.seed)
    tr_idx, va_idx = [], []
    for c in range(len(ACTION_CLASSES)):
        idx = np.where(y == c)[0]
        rng.shuffle(idx)
        k = max(1, int(len(idx) * args.val)) if len(idx) > 4 else 0
        va_idx.extend(idx[:k])
        tr_idx.extend(idx[k:])
    tr_idx = np.asarray(tr_idx, np.int64)
    va_idx = np.asarray(va_idx, np.int64)
    if len(va_idx) == 0:
        va_idx = tr_idx[:max(1, len(tr_idx) // 10)]
    print('训练 %d / 验证 %d' % (len(tr_idx), len(va_idx)))

    # 类别不均衡：idle 往往占一半，按频率反比加权
    cnt = np.bincount(y[tr_idx], minlength=len(ACTION_CLASSES)).astype(np.float64)
    cnt[cnt == 0] = 1.0
    w = (cnt.sum() / cnt) ** 0.5
    w = w / w.mean()
    print('类别权重', np.round(w, 2).tolist())
    weight = torch.tensor(w, dtype=torch.float32)

    dl_tr = DataLoader(SeqDataset(X[tr_idx], y[tr_idx], True, args.aug),
                       batch_size=args.batch, shuffle=True, num_workers=0,
                       drop_last=len(tr_idx) > args.batch)
    dl_va = DataLoader(SeqDataset(X[va_idx], y[va_idx], False),
                       batch_size=args.batch, shuffle=False, num_workers=0)

    net = ActionNet()
    opt = torch.optim.AdamW(net.parameters(), lr=args.lr, weight_decay=args.wd)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)
    lossf = nn.CrossEntropyLoss(weight=weight, label_smoothing=0.05)

    best, best_state = -1.0, None
    for ep in range(args.epochs):
        net.train()
        tot = n = 0
        for xb, yb in dl_tr:
            opt.zero_grad()
            loss = lossf(net(xb), yb)
            loss.backward()
            nn.utils.clip_grad_norm_(net.parameters(), 5.0)
            opt.step()
            tot += float(loss.item()) * len(yb)
            n += len(yb)
        sched.step()

        net.eval()
        correct = total = 0
        conf = np.zeros((len(ACTION_CLASSES), len(ACTION_CLASSES)), np.int64)
        with torch.no_grad():
            for xb, yb in dl_va:
                pred = net(xb).argmax(1)
                correct += int((pred == yb).sum())
                total += len(yb)
                for t_, p_ in zip(yb.tolist(), pred.tolist()):
                    conf[t_, p_] += 1
        acc = correct / max(1, total)
        print('ep %3d  loss %.4f  val_acc %.3f' % (ep + 1, tot / max(1, n), acc))
        if acc > best:
            best = acc
            best_state = {k: v.detach().clone() for k, v in net.state_dict().items()}

    if best_state is not None:
        net.load_state_dict(best_state)
    torch.save({'state_dict': net.state_dict(),
                'classes': ACTION_CLASSES,
                't_len': T_LEN, 'v': V_JOINTS, 'c': C_CH,
                'val_acc': best}, args.out)

    print('-' * 60)
    print('最佳 val_acc = %.3f  已保存 %s' % (best, args.out))
    print('混淆矩阵（行=真实, 列=预测）')
    head = '        ' + ' '.join('%5s' % c[:5] for c in ACTION_CLASSES)
    print(head)
    for i, c in enumerate(ACTION_CLASSES):
        print('%7s ' % c[:7] + ' '.join('%5d' % v for v in conf[i]))


if __name__ == '__main__':
    main()
