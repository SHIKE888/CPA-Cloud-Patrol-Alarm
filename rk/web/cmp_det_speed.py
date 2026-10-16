#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cmp_det_speed.py —— 对比两个检测模型在板上的推理 + 后处理耗时。

用法：python cmp_det_speed.py <图片> <模型1.rknn> [模型2.rknn ...]
"""
from __future__ import annotations

import os
import statistics
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, "/root/rk/ai/board")
import det_core as dc  # noqa: E402


def main():
    img = cv2.imread(sys.argv[1])
    if img is None:
        sys.exit("读不到图片 %s" % sys.argv[1])
    lb, s, px, py = dc.letterbox(img, (640, 640))
    rgb = np.ascontiguousarray(lb[:, :, ::-1])
    print("图片 %s  %dx%d" % (sys.argv[1], img.shape[1], img.shape[0]))

    for path in sys.argv[2:]:
        if not os.path.isfile(path):
            print("跳过（不存在）: %s" % path)
            continue
        m = dc.RKNNModel(path, "det")
        if not m.ok:
            print("%-28s 加载失败: %s" % (os.path.basename(path), m.err))
            continue
        for _ in range(5):
            outs = m.infer(rgb)

        ts = []
        for _ in range(30):
            t0 = time.perf_counter()
            outs = m.infer(rgb)
            ts.append((time.perf_counter() - t0) * 1000.0)

        t0 = time.perf_counter()
        objs = dc._decode_heads(outs, 0.35, keep_cls=[0])
        objs = dc._post(objs, 0.45, max_det=64)
        t_post = (time.perf_counter() - t0) * 1000.0

        tot = statistics.median(ts) + t_post
        print("%-24s infer %6.2f/%.2f ms + post %5.2f ms = %6.2f ms  -> %4.1f fps | %d 人 | %s"
              % (os.path.basename(path), statistics.median(ts), min(ts), t_post, tot,
                 1000.0 / tot, len(objs),
                 [int(v) for v in objs[0].box] if objs else "-"))
        m.release()


if __name__ == "__main__":
    main()
