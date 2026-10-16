#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""speed_full.py —— 用"有人"的图片测完整两级 + 跟踪 + 动作的真实每帧耗时。

用法：python speed_full.py <含人图片> [检测间隔...]
"""
from __future__ import annotations

import statistics
import sys
import time

import cv2

sys.path.insert(0, "/root/rk/ai/board")
import det_core as dc  # noqa: E402
from action_rules import ActionRecognizer  # noqa: E402

DET = "/root/rk/ai/models/yolov8n-slim.rknn"
POSE = "/root/rk/ai/models/yolov8n-pose-hybrid.rknn"

img = cv2.imread(sys.argv[1])
if img is None:
    sys.exit("读不到 %s" % sys.argv[1])
intervals = [int(x) for x in sys.argv[2:]] or [1, 2, 3]

det = dc.TwoStageDetector(DET, POSE)
n = len(det.run(img))
print("画面 %dx%d，检出 %d 人" % (img.shape[1], img.shape[0], n))
if n:
    k = det.run(img)[0]["kps"]
    print("  第一个人的有效关节数: %d/17" % int((k[:, 2] > 0).sum()) if k is not None else "  无关节")

for iv in intervals:
    det.det_interval = iv
    tracker = dc.SimpleTracker()
    acts = ActionRecognizer()
    for _ in range(3):
        d = tracker.update(time.time(), acts.update(time.time(), det.run(img)))
    ts = []
    for _ in range(15):
        t0 = time.perf_counter()
        d = det.run(img)
        d = tracker.update(t0, d)
        d = acts.update(t0, d)
        ts.append((time.perf_counter() - t0) * 1000.0)
    med = statistics.median(ts)
    print("det_interval=%d : %6.2f ms/帧 (min %6.2f) -> %5.1f fps   [det %5.1fms/pose %5.1fms/跳过 %d 个关节]"
          % (iv, med, min(ts), 1000.0 / med,
             det.stat["det_ms"], det.stat["pose_ms"], det.stat["kpt_dropped"]))
