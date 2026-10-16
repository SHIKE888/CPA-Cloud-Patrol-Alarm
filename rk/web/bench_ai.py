#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_ai.py —— 分解两级 AI 流水线各段耗时，找出真正的瓶颈。

用法（板上）：/opt/miniforge3/envs/mlk-ov/bin/python bench_ai.py [图片URL或路径] [重复次数]

输出：
  A) 各段耗时（letterbox / BGR2RGB / NPU 推理 / 后处理 / 跟踪动作）
  B) 几种预处理方案的对比（INTER_AREA vs INTER_LINEAR，numpy 翻转 vs cv2.cvtColor）
  C) 降分辨率输入（1080p vs 1280 vs 960）对耗时的影响
"""
from __future__ import annotations

import os
import statistics
import sys
import time
import urllib.request

import cv2
import numpy as np

AI = "/root/rk/ai"
sys.path.insert(0, os.path.join(AI, "board"))
import det_core as dc  # noqa: E402

SRC = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9012/snapshot.jpg"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 20
DET = os.path.join(AI, "models", "yolov8n.rknn")
POSE = os.path.join(AI, "models", "yolov8n-pose-hybrid.rknn")


def load_frame(src):
    if src.startswith(("http://", "https://")):
        p = "/tmp/bench_ai_frame.jpg"
        urllib.request.urlretrieve(src, p)
        src = p
    img = cv2.imread(src)
    if img is None:
        sys.exit("读不到画面: %s" % src)
    return img


def ms(fn, n=N):
    ts = []
    for _ in range(n):
        t0 = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t0) * 1000.0)
    return statistics.median(ts), min(ts)


def main():
    img = load_frame(SRC)
    h, w = img.shape[:2]
    print("画面 %dx%d   重复 %d 次（取中位数 / 最小值 ms）" % (w, h, N))

    det = dc.TwoStageDetector(DET, POSE)
    if not det.det.ok:
        sys.exit("检测模型不可用: %s" % det.det.err)
    print("模型 det ok=%s  pose ok=%s" % (det.det.ok, det.pose.ok))

    # ---------- 预热 ----------
    lb, scale, px, py = dc.letterbox(img, (640, 640))
    rgb = np.ascontiguousarray(lb[:, :, ::-1])
    for _ in range(5):
        outs = det.det.infer(rgb)
    dets = det.run(img)
    print("一帧里的人数: %d  (框: %s)" % (len(dets),
                                      [list(map(int, d['box'])) for d in dets]))

    # ============================================================ A) 分段
    print("\n=== A) 分段耗时 ===")

    t, tmin = ms(lambda: dc.letterbox(img, (640, 640)))
    print("  letterbox 1080p->640(INTER_AREA) : %6.2f / %6.2f" % (t, tmin))

    t, tmin = ms(lambda: np.ascontiguousarray(lb[:, :, ::-1]))
    print("  BGR->RGB numpy 翻转+拷贝         : %6.2f / %6.2f" % (t, tmin))

    t_rgb = np.ascontiguousarray(lb[:, :, ::-1])
    t, tmin = ms(lambda: det.det.infer(t_rgb))
    print("  det  NPU 推理(rknnlite 计时 %.1fms): %6.2f / %6.2f"
          % (det.det.infer_ms, t, tmin))

    o = det.det.infer(t_rgb)

    def det_post():
        objs = dc._decode_heads(o, det.det_conf, keep_cls=[0])
        dc._post(objs, det.nms_thres, max_det=64)
    t, tmin = ms(det_post)
    print("  det  后处理(decode+NMS)          : %6.2f / %6.2f" % (t, tmin))

    # pose：拿第一帧的第一个框
    if dets:
        box = dets[0]['box']

        def pose_all():
            return det.pose_in(img, box)
        t, tmin = ms(pose_all)
        print("  pose 端到端(ROI+推理+后处理)     : %6.2f / %6.2f" % (t, tmin))
        print("       (其中 NPU 推理 %.1fms)" % det.pose.infer_ms)

        # 单独看 ROI 前处理
        x1, y1, x2, y2 = box
        ex = det.roi_expand
        cx, cy = (x1 + x2) * 0.5, (y1 + y2) * 0.5
        rx1 = int(max(0, cx - (x2 - x1) * ex * 0.5))
        ry1 = int(max(0, cy - (y2 - y1) * ex * 0.5))
        rx2 = int(min(w, cx + (x2 - x1) * ex * 0.5))
        ry2 = int(min(h, cy + (y2 - y1) * ex * 0.5))

        def pose_pre():
            roi = img[ry1:ry2, rx1:rx2]
            l2, s2, p2, q2 = dc.letterbox(roi, (640, 640))
            return np.ascontiguousarray(l2[:, :, ::-1])
        t, tmin = ms(pose_pre)
        print("  pose ROI 前处理                  : %6.2f / %6.2f" % (t, tmin))

    t, tmin = ms(lambda: det.run(img), n=max(5, N // 2))
    print("  >>> 两级端到端 det.run()         : %6.2f / %6.2f  => %.1f fps"
          % (t, tmin, 1000.0 / t))

    if det.tracker is None:
        det.tracker = dc.SimpleTracker()
    from action_rules import ActionRecognizer
    det.actions = ActionRecognizer()

    def track_act():
        t0 = time.time()
        d = det.run(img)
        d = det.tracker.update(t0, d)
        det.actions.update(t0, d)
    t, tmin = ms(track_act, n=max(5, N // 2))
    print("  >>> 两级+跟踪+动作             : %6.2f / %6.2f  => %.1f fps"
          % (t, tmin, 1000.0 / t))

    # ============================================================ B) 预处理方案
    print("\n=== B) 预处理方案对比 ===")

    def lb_area():
        return dc.letterbox(img, (640, 640))

    def lb_linear():
        h0, w0 = img.shape[:2]
        r = min(640.0 / w0, 640.0 / h0)
        nw, nh = int(round(w0 * r)), int(round(h0 * r))
        rs = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
        c = np.full((640, 640, 3), 114, np.uint8)
        px0, py0 = (640 - nw) // 2, (640 - nh) // 2
        c[py0:py0 + nh, px0:px0 + nw] = rs
        return c, r, px0, py0

    def lb_rgb_cvt():
        c, r, p0, q0 = lb_linear()
        return cv2.cvtColor(c, cv2.COLOR_BGR2RGB)

    a1, _ = ms(lb_area)
    a2, _ = ms(lb_linear)
    a3, _ = ms(lambda: np.ascontiguousarray(lb_linear()[0][:, :, ::-1]))
    a4, _ = ms(lb_linear, n=N)
    print("  letterbox INTER_AREA             : %6.2f" % a1)
    print("  letterbox INTER_LINEAR           : %6.2f" % a2)
    print("  + numpy 翻转(::−1)+拷贝          : %6.2f" % a3)
    print("  + cv2.cvtColor(BGR2RGB)          : %6.2f  <-- 推荐" % ms(lb_rgb_cvt)[0])

    # ============================================================ C) 输入分辨率
    print("\n=== C) 送 AI 的画面分辨率影响 ===")
    for wid in (1920, 1280, 960, 640):
        if wid > w:
            continue
        f = cv2.resize(img, (wid, int(h * wid / w)), interpolation=cv2.INTER_AREA)
        t, _ = ms(lambda f=f: dc.letterbox(f, (640, 640)), n=max(5, N // 2))
        print("  输入宽 %4d -> letterbox : %6.2f ms" % (wid, t))


if __name__ == "__main__":
    main()
