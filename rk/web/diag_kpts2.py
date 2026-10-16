#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""diag_kpts2.py —— 查"关节飘到框外远处"为什么没被约束拦住。

流程：
  1) 临时把 9012 切到原图，抓一张干净帧（不带已画上去的标注）
  2) 打印 det_core 实例里的实际约束参数
  3) 对每个检测框，同时给出「关闭约束」与「开启约束」的 17 点坐标，
     并标出哪些点在框外 —— 一眼就能看出门限到底有没有生效
"""
from __future__ import annotations

import json
import sys
import time
import urllib.request

import cv2

sys.path.insert(0, "/root/rk/ai/board")
import det_core as dc  # noqa: E402

API = "http://127.0.0.1:9012"
NAMES = ["nose", "L_eye", "R_eye", "L_ear", "R_ear", "L_sho", "R_sho",
         "L_elb", "R_elb", "L_wri", "R_wri", "L_hip", "R_hip",
         "L_kne", "R_kne", "L_ank", "R_ank"]


def post(path, obj):
    req = urllib.request.Request(API + path, data=json.dumps(obj).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=10).read().decode("utf-8"))


def get_snapshot(dst):
    urllib.request.urlretrieve(API + "/snapshot.jpg", dst)
    return cv2.imread(dst)


def main():
    print("== 切到原图抓一张干净帧（诊断用，随后切回 AI）")
    try:
        post("/api/ai", {"source": "raw"})
        time.sleep(2.0)
        img = get_snapshot("/tmp/diag_raw.jpg")
    finally:
        post("/api/ai", {"source": "ai"})
    if img is None:
        sys.exit("抓帧失败")
    print("   干净帧 %dx%d" % (img.shape[1], img.shape[0]))

    det = dc.TwoStageDetector("/root/rk/ai/models/yolov8n-slim.rknn",
                              "/root/rk/ai/models/yolov8n-pose-hybrid.rknn")
    print("== det_core 实例里的实际参数")
    print("   kpt_margin=%s  kpt_scale_max=%s  kpt_conf=%s  roi_expand=%s"
          % (det.kpt_margin, det.kpt_scale_max, det.kpt_conf, det.roi_expand))

    boxes = det.persons(img)
    print("== 检测框 %d 个: %s" % (len(boxes), [tuple(int(v) for v in b) for b, _ in boxes]))

    for bi, (box, sc) in enumerate(boxes):
        x1, y1, x2, y2 = [float(v) for v in box]
        bw, bh = x2 - x1, y2 - y1
        print("\n--- 框#%d (%d %d %d %d)  宽%.0f 高%.0f  score=%.2f  "
              "允许范围 x[%.0f,%.0f] y[%.0f,%.0f]"
              % (bi, x1, y1, x2, y2, bw, bh, sc,
                 x1 - bw * 0.15, x2 + bw * 0.15, y1 - bh * 0.15, y2 + bh * 0.15))

        det.kpt_margin, det.kpt_scale_max = -1.0, 0.0      # 关闭约束
        raw = det.pose_in(img, box)
        det.kpt_margin, det.kpt_scale_max = 0.15, 2.5       # 打开约束
        fil = det.pose_in(img, box)
        if raw is None or fil is None:
            print("   pose_in 返回 None")
            continue

        for i in range(17):
            rx, ry, rc = raw[i]
            fx, fy, fc = fil[i]
            flag = ""
            if rx < x1 - bw * 0.15 or rx > x2 + bw * 0.15 or \
               ry < y1 - bh * 0.15 or ry > y2 + bh * 0.15:
                flag = " <框外"
            if fc <= 0 < rc:
                flag += "  [已被约束剔除]"
            print("   %-6s raw(%6.1f,%6.1f,%.2f)%s  filt(%6.1f,%6.1f,%.2f)"
                  % (NAMES[i], rx, ry, rc, flag, fx, fy, fc))

        # 体型尺度参考
        s = dc._body_scale(raw)
        print("   躯干长(体型基准) = %.1f  → 体型门限 = %.1f" % (s[0], 2.5 * s[0]))


if __name__ == "__main__":
    main()
