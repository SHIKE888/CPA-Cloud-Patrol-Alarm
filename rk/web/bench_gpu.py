#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_gpu.py —— 对比 letterbox 在 CPU 与 GPU(OpenCL/UMat) 上的耗时。

RK3576 的 GPU 是 Mali-G52，板上 OpenCL 可用（cv2.ocl.haveOpenCL() = True）。
但 AI 推理本身跑 NPU，能交给 GPU 的只有**前处理**（resize + BGR→RGB）。

要注意 T-API 的两个隐藏成本（本脚本会分开测出来）：
  1. 上传：1920×1080×3 = 6.2 MB numpy -> UMat
  2. 下载：640×640×3  = 1.2 MB UMat -> numpy
只测"计算"而不测传输，很容易得出错误结论。

用法: python bench_gpu.py [图片]
"""
from __future__ import annotations

import statistics
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, '/root/rk/ai/board')
import det_core as dc  # noqa: E402


def bench(fn, n=15, warm=3):
    for _ in range(warm):
        fn()
    ts = []
    for _ in range(n):
        t = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t) * 1000.0)
    return statistics.median(ts)


src = cv2.imread(sys.argv[1] if len(sys.argv) > 1 else '')
if src is None:
    sys.exit('读不到图片')
img = cv2.resize(src, (1920, 1080))
print('输入 1920x1080   cv2 %s   OpenCL=%s (%s)'
      % (cv2.__version__, cv2.ocl.haveOpenCL(),
         cv2.ocl.Device_getDefault().name() if cv2.ocl.haveOpenCL() else '-'))

# 目标：letterbox 到 640（1080p 等比 => 640x360 + 上下填充）
nw, nh = 640, 360
u_src = cv2.UMat(img)                     # 预先上传，只测计算
u_res = cv2.UMat(640, 360, cv2.CV_8UC3)
u_rgb = cv2.UMat(640, 360, cv2.CV_8UC3)


def cpu_letterbox():
    return dc.letterbox_rgb(img, (640, 640), interp=cv2.INTER_LINEAR)


def cpu_bare():
    r = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    return cv2.cvtColor(r, cv2.COLOR_BGR2RGB)


def gpu_upload_only():
    return cv2.UMat(img)


def gpu_compute_only():
    cv2.resize(u_src, (nw, nh), dst=u_res, interpolation=cv2.INTER_LINEAR)
    cv2.cvtColor(u_res, cv2.COLOR_BGR2RGB, dst=u_rgb)


def gpu_full():
    u = cv2.UMat(img)
    u2 = cv2.resize(u, (nw, nh), interpolation=cv2.INTER_LINEAR)
    u3 = cv2.cvtColor(u2, cv2.COLOR_BGR2RGB)
    return u3.get()


print('-' * 58)
print('%-34s %8s' % ('CPU: dc.letterbox_rgb (线上现状)', bench(cpu_letterbox)))
print('%-34s %8s' % ('CPU: resize + cvtColor (无画布)', bench(cpu_bare)))
print('%-34s %8s' % ('GPU: 只上传 1080p (6.2MB)', bench(gpu_upload_only)))
print('%-34s %8s' % ('GPU: 只计算 (已常驻 UMat)', bench(gpu_compute_only)))
print('%-34s %8s' % ('GPU: 上传+计算+下载 (真实用法)', bench(gpu_full)))
print('-' * 58)

# 再单独看一遍大图的纯转色（YUV->BGR 之前是 CPU 大头，这里看 BGR->RGB 的量级）
print('%-34s %8s' % ('CPU: 1080p BGR->RGB', bench(lambda: cv2.cvtColor(img, cv2.COLOR_BGR2RGB))))
print('%-34s %8s' % ('CPU: 1080p -> 640x360 resize', bench(
    lambda: cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR))))
print('OpenCL 状态: use=%s  threads=%d' % (cv2.ocl.useOpenCL(), cv2.getNumThreads()))
