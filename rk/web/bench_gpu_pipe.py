#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_gpu_pipe.py —— GPU 到底有没有正收益？四种组合横评。

上次只测了"单线程里 letterbox 的墙钟"，结论是 GPU 慢。但 GPU 是独立硬件，
真正的机会在**流水**：后台线程做前处理，主线程跑 NPU，两者重叠。
本脚本把四种组合放在一起比，避免再漏掉这种可能：

  A 串行 CPU   : letterbox(CPU) -> infer          （线上现状）
  B 串行 GPU   : letterbox(UMat) -> infer
  C 流水 CPU   : 后台线程 letterbox(CPU)  || 主线程 infer
  D 流水 GPU   : 后台线程 letterbox(UMat) || 主线程 infer

注意：流水实验里前处理结果必须 copy 一份再交给主线程，否则后台线程
写下一帧时会就地覆盖推理正在读的缓冲（真实业务里同样要双缓冲）。

用法: python bench_gpu_pipe.py [图片]
"""
from __future__ import annotations

import queue
import statistics
import sys
import threading
import time

import cv2
import numpy as np

sys.path.insert(0, '/root/rk/ai/board')
import det_core as dc  # noqa: E402

DET = '/root/rk/ai/models/yolov8n-slim.rknn'
N = 14


def lb_cpu():
    return dc.letterbox_rgb(img, (640, 640), interp=cv2.INTER_LINEAR, slot='bench')[0]


# GPU 分支同样复用画布，否则比的是“复用 vs 不复用”，不是 CPU vs GPU
_G = {'buf': None}


def lb_gpu():
    u = cv2.UMat(img)
    u2 = cv2.resize(u, (640, 360), interpolation=cv2.INTER_LINEAR)
    small = cv2.cvtColor(u2, cv2.COLOR_BGR2RGB).get()
    buf = _G['buf']
    if buf is None:
        buf = np.full((640, 640, 3), 114, dtype=np.uint8)
        _G['buf'] = buf
    buf[140:500, :] = small
    return buf


def seq(fn):
    for _ in range(3):
        det.infer(fn())
    ts = []
    for _ in range(N):
        t = time.perf_counter()
        det.infer(fn())
        ts.append((time.perf_counter() - t) * 1000.0)
    return statistics.median(ts)


def pipe(fn):
    """单槽流水：后台线程产 rgb（copy 一份），主线程消费并推理。"""
    q = queue.Queue(maxsize=1)
    stop = threading.Event()

    def worker():
        while not stop.is_set():
            try:
                q.put(fn().copy(), timeout=0.05)
            except queue.Full:
                pass

    th = threading.Thread(target=worker, daemon=True)
    th.start()
    for _ in range(3):                                # 预热
        det.infer(q.get())
    ts = []
    for _ in range(N):
        t = time.perf_counter()
        det.infer(q.get())
        ts.append((time.perf_counter() - t) * 1000.0)
    stop.set()
    th.join(timeout=1.0)
    return statistics.median(ts)


img = cv2.imread(sys.argv[1] if len(sys.argv) > 1 else '')
if img is None:
    sys.exit('读不到图片')
img = cv2.resize(img, (1920, 1080))
det = dc.RKNNModel(DET, 'det')
if not det.ok:
    sys.exit('模型加载失败: %s' % det.err)

print('输入 1920x1080   OpenCL=%s (%s)'
      % (cv2.ocl.haveOpenCL(),
         cv2.ocl.Device_getDefault().name() if cv2.ocl.haveOpenCL() else '-'))
print('-' * 56)
rows = [
    ('A 串行 CPU  letterbox -> infer', lambda: seq(lb_cpu)),
    ('B 串行 GPU  letterbox -> infer', lambda: seq(lb_gpu)),
    ('C 流水 CPU  后台 letterbox || infer', lambda: pipe(lb_cpu)),
    ('D 流水 GPU  后台 letterbox || infer', lambda: pipe(lb_gpu)),
]
for name, fn in rows:
    ms = fn()
    print('%-38s %7.2f ms  %5.1f fps' % (name, ms, 1000.0 / ms))
print('-' * 56)
print('（det.infer 单次约 %.1f ms 是共同下限）' % det.infer_ms)
