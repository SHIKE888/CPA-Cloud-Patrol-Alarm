#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""diag_kpts.py —— 诊断关键点"异常飘到偏左上"的来源。

对同一张图连续跑 N 次，并列打印：
  A) 模型原始输出（只过 det_core，不经跟踪/平滑）
  B) 经 SimpleTracker 平滑后的输出
  C) 对应的框（检测框 / 回写后的框）

判读：
  * A 稳定而 B 漂移  -> 平滑逻辑把"无效帧的鬼坐标"混进来了（tracker 的锅）
  * A 本身就飘       -> 是姿态模型输出 + 解码/坐标还原的问题
  * C 的框也在左移   -> 跳帧时"用关节外接框回写"形成了正反馈
"""
from __future__ import annotations

import os
import statistics
import sys
import time
import urllib.request

import cv2
import numpy as np

sys.path.insert(0, "/root/rk/ai/board")
import det_core as dc  # noqa: E402

NAMES = ["nose", "L_eye", "R_eye", "L_ear", "R_ear",
         "L_sho", "R_sho", "L_elb", "R_elb", "L_wri", "R_wri",
         "L_hip", "R_hip", "L_kne", "R_kne", "L_ank", "R_ank"]
SHOW = [0, 5, 6, 9, 10, 11, 12, 15, 16]

SRC = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9012/snapshot.jpg"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 8
INTERVAL = int(sys.argv[3]) if len(sys.argv) > 3 else 2


def load(src):
    if src.startswith(("http://", "https://")):
        p = "/tmp/diag_kpts.jpg"
        urllib.request.urlretrieve(src, p)
        src = p
    im = cv2.imread(src)
    if im is None:
        sys.exit("读不到 %s" % src)
    return im


def fmt_box(b):
    return "(%4d %4d %4d %4d)" % tuple(int(v) for v in b)


def main():
    img = load(SRC)
    h, w = img.shape[:2]
    print("画面 %dx%d   det_interval=%d   重复 %d 次" % (w, h, INTERVAL, N))

    det = dc.TwoStageDetector("/root/rk/ai/models/yolov8n-slim.rknn",
                              "/root/rk/ai/models/yolov8n-pose-hybrid.rknn",
                              det_interval=INTERVAL)
    boxes = det.persons(img)
    print("检测到 %d 人:  %s" % (len(boxes), [fmt_box(b) for b, _ in boxes]))
    if not boxes:
        sys.exit("没有人，换个有人的画面再试")

    tr = dc.SimpleTracker()
    vis = img.copy()
    prev_raw = {}

    print("\n=== A) 模型原始输出（每次直接用同一个检测框，看模型本身稳不稳） ===")
    print("     %s" % "   ".join("%-15s" % n for n in [NAMES[i] for i in SHOW]))
    raw_traj = {i: [] for i in SHOW}
    box0 = boxes[0][0]
    for k in range(N):
        kps = det.pose_in(img, box0)
        if kps is None:
            print("  #%d  pose_in 返回 None" % k)
            continue
        cells = []
        for i in SHOW:
            x, y, c = kps[i]
            cells.append("%4.0f,%4.0f,%3.2f" % (x, y, c))
            if c > 0:
                raw_traj[i].append((x, y))
        print("  #%d  %s" % (k, "  ".join(cells)))
    print("  -> 各点原始输出的极差（像素）：")
    for i in SHOW:
        t = raw_traj[i]
        if len(t) >= 2:
            xs = [p[0] for p in t]
            ys = [p[1] for p in t]
            print("     %-7s dx=%5.1f  dy=%5.1f  n=%d" % (NAMES[i], max(xs) - min(xs),
                                                          max(ys) - min(ys), len(t)))

    print("\n=== B) 经 SimpleTracker 平滑后（同一张图反复喂，看会不会漂） ===")
    det.det_interval = INTERVAL
    traj = {i: [] for i in SHOW}
    for k in range(N):
        t = time.time()
        d = det.run(img)
        d = tr.update(t, d)
        if not d:
            print("  #%d  无检测" % k)
            continue
        p = d[0]
        kps = p.get("kps")
        cells = []
        for i in SHOW:
            if kps is None:
                cells.append("     -        ")
                continue
            x, y, c = kps[i]
            cells.append("%4.0f,%4.0f,%3.2f" % (x, y, c))
            if c > 0:
                traj[i].append((x, y))
        print("  #%d box=%s  %s" % (k, fmt_box(p["box"]), "  ".join(cells)))
        if kps is not None:
            for a, b in dc.SKELETON:
                if kps[a][2] > 0 and kps[b][2] > 0:
                    cv2.line(vis, (int(kps[a][0]), int(kps[a][1])),
                             (int(kps[b][0]), int(kps[b][1])), (0, 200, 255), 2, cv2.LINE_AA)
            for i in range(17):
                if kps[i][2] > 0:
                    cv2.circle(vis, (int(kps[i][0]), int(kps[i][1])), 3, (0, 0, 255), -1)
    print("\n  -> 平滑后各点的漂移（像素）：")
    for i in SHOW:
        t = traj[i]
        if len(t) >= 2:
            xs = [p[0] for p in t]
            ys = [p[1] for p in t]
            print("     %-7s dx=%5.1f  dy=%5.1f" % (NAMES[i], max(xs) - min(xs),
                                                 max(ys) - min(ys)))

    cv2.imwrite("/root/rk/web/diag_kpts.jpg", vis)
    print("\n结果图: /root/rk/web/diag_kpts.jpg")
    print("统计: kpt_dropped=%s kpt_far=%s" % (det.stat.get("kpt_dropped"),
                                             det.stat.get("kpt_far")))


if __name__ == "__main__":
    main()
