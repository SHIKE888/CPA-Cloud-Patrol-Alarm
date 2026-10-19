#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""prof_ai.py —— 把两级 detector.run() 拆成可归因的几段，找 CPU / NPU 的真实占比。

用法: python prof_ai.py <含人图片> [det模型] [pose模型]

结论怎么看：
  * det.infer / pose.infer  = NPU 侧（含 rknnlite 的 NHWC->NCHW 转换）
  * letterbox / decode / NMS = CPU 侧前后处理
  两者相加 ≈ run()，差出来的就是“还能并行掉”的空间。
"""
from __future__ import annotations

import statistics
import sys
import time

import cv2

sys.path.insert(0, '/root/rk/ai/board')
import det_core as dc  # noqa: E402

DET = sys.argv[2] if len(sys.argv) > 2 else '/root/rk/ai/models/yolov8n-slim.rknn'
POSE = sys.argv[3] if len(sys.argv) > 3 else '/root/rk/ai/models/yolov8n-pose-hybrid.rknn'


def bench(fn, n=12):
    for _ in range(2):
        fn()
    ts = []
    for _ in range(n):
        t = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t) * 1000.0)
    return statistics.median(ts)


img = cv2.imread(sys.argv[1] if len(sys.argv) > 1 else '')
if img is None:
    sys.exit('读不到图片')

det = dc.TwoStageDetector(DET, POSE)
print('图片 %dx%d  det=%s  pose=%s' % (img.shape[1], img.shape[0],
                                      DET.split('/')[-1], POSE.split('/')[-1]))
print('-' * 62)
print('%-28s %8s' % ('阶段', 'ms'))

print('%-28s %8.2f' % ('letterbox 1080p -> 640',
                       bench(lambda: dc.letterbox_rgb(img, (640, 640)))))

rgb, scale, px, py = dc.letterbox_rgb(img, (640, 640))
print('%-28s %8.2f' % ('det.infer   (NPU)', bench(lambda: det.det.infer(rgb))))

outs = det.det.infer(rgb)
print('%-28s %8.2f' % ('_decode_heads (CPU)',
                       bench(lambda: dc._decode_heads(outs, 0.35, keep_cls=[0],
                                                      input_size=640))))
objs = dc._decode_heads(outs, 0.35, keep_cls=[0], input_size=640)
print('   (候选框 %d 个)' % len(objs))
print('%-28s %8.2f' % ('_post NMS (CPU)',
                       bench(lambda: dc._post(objs, 0.45, max_det=64))))
print('%-28s %8.2f' % ('persons() 合计', bench(lambda: det.persons(img))))

boxes = det.persons(img)
print('   (检出 %d 人)' % len(boxes))
if boxes:
    box = boxes[0][0]
    print('%-28s %8.2f' % ('pose_in() 合计', bench(lambda: det.pose_in(img, box))))
    print('%-28s %8.2f' % ('  pose.infer (NPU)', det.pose.infer_ms))
print('-' * 62)
ms = bench(lambda: det.run(img))
print('%-28s %8.2f  -> %.1f fps' % ('detector.run() 合计', ms, 1000.0 / ms))
print('   stat: det %.2fms / pose %.2fms' % (det.stat['det_ms'], det.stat['pose_ms']))
