#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_multi.py —— 用 2x2 拼接图模拟多人，对比「姿态预算 pose_budget」的效果。

用法: python bench_multi.py <含人图片>

同一张图拼成 2x2 后，检测器会真的检出 4 个人（不是假数据），
所以能真实反映"姿态逐人串行"在人多时把帧率拉垮的程度，
以及 pose_budget 限成 2 之后帧率能稳住多少。
"""
from __future__ import annotations

import statistics
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, '/root/rk/ai/board')
import det_core as dc  # noqa: E402

DET = '/root/rk/ai/models/yolov8n-slim.rknn'
POSE = '/root/rk/ai/models/yolov8n-pose-hybrid.rknn'

src = cv2.imread(sys.argv[1] if len(sys.argv) > 1 else '')
if src is None:
    sys.exit('读不到图片')

# 2x2 拼图 -> 缩到 1920 宽，接近真实采集分辨率
h, w = src.shape[:2]
grid = np.full((h * 2, w * 2, 3), 114, dtype=np.uint8)
for i in range(2):
    for j in range(2):
        grid[i * h:(i + 1) * h, j * w:(j + 1) * w] = src
grid = cv2.resize(grid, (1920, int(grid.shape[0] * 1920.0 / grid.shape[1])))

det = dc.TwoStageDetector(DET, POSE)
det.det_interval = 2          # 线上默认（帧率优先档）
det.spread_pose = True
det.max_persons = 4

n = len(det.run(grid))
print('拼接图 %dx%d  检出 %d 人' % (grid.shape[1], grid.shape[0], n))
print('%-14s %10s %10s %10s' % ('pose_budget', 'ms/帧', 'fps', '跳过帧'))
print('-' * 48)
for budget in (0, 1, 2, 3, 4):
    det.pose_budget = budget
    det._pose_rr = 0
    det._prev_pose = []
    skip0 = det.stat['pose_skip']
    for _ in range(4):                     # 预热，让缓存/关节都就位
        det.run(grid)
    ts = []
    for _ in range(12):
        t0 = time.perf_counter()
        det.run(grid)
        ts.append((time.perf_counter() - t0) * 1000.0)
    ms = statistics.median(ts)
    print('%-14s %10.2f %10.1f %10d'
          % ('不限' if budget == 0 else str(budget), ms, 1000.0 / ms,
             det.stat['pose_skip'] - skip0))
