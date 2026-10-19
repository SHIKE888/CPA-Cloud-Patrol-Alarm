#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_stream_jitter.py —— 测 MJPEG 流的帧间隔分布（"帧率没变但看着卡"的客观指标）。

平均帧率相同，观感可能完全不同：
  * 均匀 58fps（17ms 一帧）→ 顺滑
  * 平均 58fps 但夹杂 8ms/35ms → 眼睛看到的是"一顿一顿"、拖影

用法: python bench_stream_jitter.py [port] [秒数]
"""
from __future__ import annotations

import http.client
import statistics
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9012
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0

conn = http.client.HTTPConnection('127.0.0.1', PORT, timeout=15)
conn.request('GET', '/stream')
resp = conn.getresponse()

ts = []
t0 = time.time()
try:
    while time.time() - t0 < DUR:
        d = resp.read(16384)
        if not d:
            break
        now = time.time()
        ts.extend([now] * d.count(b'\xff\xd8\xff'))      # JPEG SOI 计数
finally:
    conn.close()

if len(ts) < 20:
    sys.exit('帧太少(%d)，流可能没起来' % len(ts))

gaps = [(ts[i + 1] - ts[i]) * 1000.0 for i in range(len(ts) - 1)]
gaps.sort()
n = len(gaps)
avg = (ts[-1] - ts[0]) / (len(ts) - 1) * 1000.0
p = lambda q: gaps[min(n - 1, int(n * q))]

print('采样 %d 帧 / %.1fs' % (len(ts), ts[-1] - ts[0]))
print('  平均帧间隔 : %6.2f ms   -> %.1f fps' % (avg, 1000.0 / avg))
print('  中位数     : %6.2f ms' % statistics.median(gaps))
print('  p90 / p99  : %6.2f / %6.2f ms' % (p(0.90), p(0.99)))
print('  最小 / 最大: %6.2f / %6.2f ms' % (gaps[0], gaps[-1]))
print('  抖动(stdev): %6.2f ms' % statistics.pstdev(gaps))
# 粗直方图
buckets = [(0, 12), (12, 18), (18, 24), (24, 34), (34, 50), (50, 999)]
print('  间隔分布:')
for lo, hi in buckets:
    c = sum(1 for g in gaps if lo <= g < hi)
    bar = '#' * int(round(c * 40.0 / n))
    print('    %3d-%3d ms : %4d  %s' % (lo, min(hi, 999), c, bar))
