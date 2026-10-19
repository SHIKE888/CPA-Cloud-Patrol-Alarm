#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_npu_core.py —— 测不同 NPU 核掩码下模型的单次推理墙钟。

RK3576 的 NPU 是**双核**（/sys/kernel/debug/rknpu/load 会报 Core0/Core1），
而 rknnlite 默认 NPU_CORE_AUTO 只会挑一个核跑 → 另一个核全程 0%，表现为
“NPU 占用只有 20~40% 却跑不快”。

用法:
    python probe_npu_core.py <含人图片> [模型路径 ...]

默认测线上在用的两个模型（det 640 slim / pose 640 hybrid）。
"""
from __future__ import annotations

import re
import statistics
import sys
import time

import cv2
from rknnlite.api import RKNNLite

DETS = '/root/rk/ai/models/yolov8n-slim.rknn'
POSES = '/root/rk/ai/models/yolov8n-pose-hybrid.rknn'
MASKS = ('NPU_CORE_AUTO', 'NPU_CORE_0', 'NPU_CORE_1', 'NPU_CORE_0_1')

MODELS = sys.argv[2:] or [DETS, POSES]


def size_of(path):
    """从文件名猜输入边长（yolov8n-pose-384-hybrid.rknn -> 384），默认 640。"""
    m = re.search(r'-(\d{3})-', path)
    return int(m.group(1)) if m else 640


def npu_load():
    try:
        with open('/sys/kernel/debug/rknpu/load') as f:
            return f.read().strip().replace('\n', ' ')
    except Exception:                                           # noqa: BLE001
        return '?'


img = cv2.imread(sys.argv[1] if len(sys.argv) > 1 else '')
if img is None:
    sys.exit('读不到图片: %s' % (sys.argv[1] if len(sys.argv) > 1 else '(空)'))

print('图片 %dx%d / NPU %s' % (img.shape[1], img.shape[0], npu_load()))
for path in MODELS:
    s = size_of(path)
    x = cv2.resize(img, (s, s))
    x = cv2.cvtColor(x, cv2.COLOR_BGR2RGB)[None]
    print('\n== %s  (输入 %d) ==' % (path.split('/')[-1], s))
    base = None
    for name in MASKS:
        mask = getattr(RKNNLite, name)
        r = RKNNLite(verbose=False)
        if r.load_rknn(path) != 0:
            print('  %-13s load_rknn 失败' % name)
            continue
        if r.init_runtime(core_mask=mask) != 0:
            print('  %-13s init_runtime 失败' % name)
            r.release()
            continue
        for _ in range(3):                                      # 预热
            r.inference(inputs=[x], data_format='nhwc')
        ts = []
        for _ in range(10):
            t0 = time.perf_counter()
            r.inference(inputs=[x], data_format='nhwc')
            ts.append((time.perf_counter() - t0) * 1000.0)
        med = statistics.median(ts)
        if base is None:
            base, tag = med, ''
        else:
            tag = '  %+.0f%%' % ((med / base - 1.0) * 100.0)
        print('  %-13s %6.2f ms  (min %5.2f)  -> %5.1f fps%s'
              % (name, med, min(ts), 1000.0 / med, tag))
        r.release()
print('\nNPU %s' % npu_load())
