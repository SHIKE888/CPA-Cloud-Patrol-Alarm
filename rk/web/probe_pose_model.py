#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_pose_model.py —— 检查一个 pose 模型的输出是否健康，并测单次推理耗时。

要判断的三件事：
  1. 类别分支有没有被量化压死（候选框数 = 0 就是"有框无骨架"的元凶）
  2. 关键点置信度还在不在（>0.3 的点数，正常 13~17）
  3. 单次 NPU 推理墙钟

用法: python probe_pose_model.py <model.rknn> <输入边长>
"""
from __future__ import annotations

import statistics
import sys
import time

import cv2

sys.path.insert(0, '/root/rk/ai/board')
import det_core as dc  # noqa: E402

DET = '/root/rk/ai/models/yolov8n-slim.rknn'
IMG = '/root/rk/ai/000000000139.jpg'


def roi_of(img, box, expand=1.15):
    h, w = img.shape[:2]
    x1, y1, x2, y2 = [float(v) for v in box]
    cx, cy = (x1 + x2) * 0.5, (y1 + y2) * 0.5
    rw, rh = (x2 - x1) * expand, (y2 - y1) * expand
    return (int(max(0, cx - rw * 0.5)), int(max(0, cy - rh * 0.5)),
            int(min(w, cx + rw * 0.5)), int(min(h, cy + rh * 0.5)))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, size = sys.argv[1], int(sys.argv[2])
    img = cv2.imread(IMG)
    if img is None:
        sys.exit('读不到 %s' % IMG)

    det = dc.TwoStageDetector(DET, None)                 # 只要一级，拿人的框
    boxes = det.persons(img)
    if not boxes:
        sys.exit('一级没检出人，换张图')
    x1, y1, x2, y2 = roi_of(img, boxes[0][0])
    roi = img[y1:y2, x1:x2]
    rgb, scale, px, py = dc.letterbox_rgb(roi, (size, size), slot='probe')

    m = dc.RKNNModel(path, 'pose')
    if not m.ok:
        sys.exit('加载失败: %s' % m.err)
    outs = m.infer(rgb)
    print('%-34s 输入 %3d  ROI %dx%d' % (path.split('/')[-1], size, roi.shape[1], roi.shape[0]))
    print('  输出: %s' % [tuple(o.shape) for o in outs])

    n = len(dc._decode_heads(outs, 0.20, keep_cls=[0], want_kps=True, input_size=size))
    objs = dc._decode_heads(outs, 0.20, keep_cls=[0], want_kps=True, input_size=size)
    print('  候选框(conf>0.20): %-4d  %s' % (n, 'OK' if n > 0 else '<<< 类别分支死了'))

    kp = objs[0].kps if objs else None
    if kp is None:
        print('  拿不到关键点（解码后 kps=None）  <<< 有框无骨架')
    else:
        best = kp[:, 2]
        print('  关键点 conf: max %.3f  点数(>0.3) %d/17  %s'
              % (float(best.max()), int((best > 0.3).sum()),
                 'OK' if int((best > 0.3).sum()) >= 10 else '<<< 置信度丢失'))

    ts = []
    for _ in range(14):
        t = time.perf_counter()
        m.infer(rgb)
        ts.append((time.perf_counter() - t) * 1000.0)
    print('  infer 中位 %.2f ms  (min %.2f)' % (statistics.median(ts), min(ts)))


main()
