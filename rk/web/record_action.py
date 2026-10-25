#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""动作样本采集器（跑在板子上，不额外占 NPU）。

原理：不去重新推理，而是**轮询**测流进程已经算好的关键点
（`GET /api/ai/keypoints`），按 tid 缓存最近 4 秒的骨架，每 hop 秒裁一段
32 帧的序列存成 npz。这样采集时 AI 负载完全不增加。

板上用法
--------
    cd /root/rk/web
    P=/opt/miniforge3/envs/mlk-ov/bin/python

    # 每类采 60s（--hop 0.4 → 约 150 段）
    $P record_action.py --label idle  --seconds 60 --out /root/rk/ai/data
    $P record_action.py --label swing --seconds 60 --out /root/rk/ai/data
    ...
    # 查看已采数量
    $P record_action.py --stats --out /root/rk/ai/data

采集要点（很重要，直接决定模型好坏）
------------------------------------
* `idle` 必须采最多，且**要刻意包含误报源**：走路、弯腰捡东西、说话挥手、
  双手插兜、整理头发、坐着双手放腿上、伸懒腰。模型学会这些不是目标动作，
  才不会再乱报。
* 每个动作至少换 2~3 个距离（近/中/远）、2 个角度、左右手各来一遍。
* 同一个人反复做同一动作采到的样本分布很窄，最好换人。
* 采集时保持画面里**只有一个人**，多人会互相干扰 tid。
"""
import argparse
import json
import os
import sys
import time
import urllib.request

import numpy as np

for _p in ('/root/rk/ai/board', os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                             '..', 'ai', 'board')):
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)

from action_seq import SeqBuffer, T_LEN, normalize_frame, resample   # noqa: E402

LABELS = ['idle', 'fall', 'climb', 'fight', 'run',
          'handup', 'squat', 'swing', 'throw', 'photo']


def fetch(url, timeout=1.0):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


def pick_primary(tracks):
    """多人时取面积最大的那个 —— 通常是最靠近相机、关键点最全的人。"""
    if not tracks:
        return None
    def area(d):
        b = d.get('box') or [0, 0, 0, 0]
        return (b[2] - b[0]) * (b[3] - b[1])
    return max(tracks, key=area)


def show_stats(out_dir):
    print('%-8s %6s' % ('label', 'samples'))
    total = 0
    for lab in LABELS:
        d = os.path.join(out_dir, lab)
        n = len([f for f in os.listdir(d) if f.endswith('.npz')]) if os.path.isdir(d) else 0
        total += n
        print('%-8s %6d' % (lab, n))
    print('-' * 16)
    print('%-8s %6d' % ('total', total))
    low = [l for l in LABELS if os.path.isdir(os.path.join(out_dir, l)) and
           len([f for f in os.listdir(os.path.join(out_dir, l))
                if f.endswith('.npz')]) < 40]
    if low:
        print('样本偏少的类别:', ', '.join(low))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--label', default='', choices=[''] + LABELS)
    ap.add_argument('--seconds', type=float, default=60.0)
    ap.add_argument('--hop', type=float, default=0.4, help='每隔多久切一段样本(秒)')
    ap.add_argument('--out', default='/root/rk/ai/data')
    ap.add_argument('--host', default='http://127.0.0.1:9012')
    ap.add_argument('--stats', action='store_true')
    ap.add_argument('--min-kpt', type=int, default=10,
                    help='有效关键点少于这个数就丢弃该段（半身/遮挡）')
    ap.add_argument('--max-kpt', type=int, default=0,
                    help='>0 时只用有效关键点数在 [min,max] 之间的段')
    args = ap.parse_args()

    if args.stats:
        show_stats(args.out)
        return
    if not args.label:
        raise SystemExit('需要 --label 或 --stats')

    dst = os.path.join(args.out, args.label)
    os.makedirs(dst, exist_ok=True)
    url = args.host.rstrip('/') + '/api/ai/keypoints'

    buf = SeqBuffer(maxlen=200)
    tid_cur = None
    t_end = time.time() + args.seconds
    next_save = time.time() + 1.0 + args.hop     # 前 1 秒让缓冲攒满
    saved = 0
    tries = 0
    err = ''

    print('采集 [%s] %.0fs -> %s' % (args.label, args.seconds, dst))
    print('（画面里保持单人；做动作用单侧手，距离/角度换几次）')
    while time.time() < t_end:
        t0 = time.time()
        try:
            js = fetch(url)
            err = ''
        except Exception as e:                          # noqa: BLE001
            err = str(e)
            time.sleep(0.1)
            continue
        tries += 1
        prim = pick_primary(js.get('tracks') or [])
        if prim is None:
            time.sleep(0.02)
            continue
        tid = prim.get('tid')
        if tid != tid_cur:
            tid_cur = tid
            buf = SeqBuffer(maxlen=200)       # 换人：缓冲清空，避免拼接两段骨架
        now = float(js.get('t') or time.time())
        buf.push(now, np.asarray(prim['kps'], np.float32), prim['box'])

        if time.time() >= next_save:
            next_save = time.time() + args.hop
            if buf.ready(T_LEN):
                seq = buf.build(T_LEN)
                n_valid = int((seq[:, :, 2] > 0).sum(axis=1).mean())
                ok = n_valid >= args.min_kpt and (
                    args.max_kpt <= 0 or n_valid <= args.max_kpt)
                if ok:
                    fn = os.path.join(dst, '%s_%d_%03d.npz'
                                      % (args.label, int(time.time()), saved))
                    np.savez(fn, seq=seq.astype(np.float32),
                             label=np.array(args.label))
                    saved += 1
                    print('  + %-42s kpt=%.0f' % (os.path.basename(fn), n_valid), flush=True)
                else:
                    print('  . 丢帧(有效关键点 %.0f < %d)' % (n_valid, args.min_kpt))
        dt = time.time() - t0
        if dt < 0.03:
            time.sleep(0.03 - dt)

    print('-' * 60)
    print('采集完成：%d 段 -> %s（轮询 %d 次%s）'
          % (saved, dst, tries, ('，最后错误: ' + err) if err else ''))


if __name__ == '__main__':
    main()
