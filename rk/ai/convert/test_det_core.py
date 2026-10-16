#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_det_core.py —— 在 x86 上用 onnxruntime 给 det_core 的解码逻辑做回归测试。

目的：板上调试成本高，先在 VM/PC 上确认 det_core._decode_heads / _post 与
      独立验证脚本 verify_onnx.py 结果一致，且坐标系映射正确。

用法：
  python test_det_core.py <image> --board-dir . --det yolov8n.onnx --pose yolov8n-pose.onnx
"""
from __future__ import annotations

import argparse
import os
import sys

import cv2
import numpy as np


def run_ort(path, inp):
    import onnxruntime as ort
    s = ort.InferenceSession(path, providers=['CPUExecutionProvider'])
    return s.run(None, {s.get_inputs()[0].name: inp})


def to_input(letterboxed_bgr):
    x = letterboxed_bgr[:, :, ::-1].astype(np.float32) / 255.0
    return np.ascontiguousarray(x.transpose(2, 0, 1)[None])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('--board-dir', default='.')
    ap.add_argument('--det', default='yolov8n.onnx')
    ap.add_argument('--pose', default='yolov8n-pose.onnx')
    args = ap.parse_args()

    sys.path.insert(0, os.path.abspath(args.board_dir))
    import det_core as dc

    img = cv2.imread(args.image)
    if img is None:
        sys.exit('读不到 %s' % args.image)
    H, W = img.shape[:2]
    print('image %dx%d' % (W, H))

    # ---------------- Stage 1
    lb, scale, px, py = dc.letterbox(img, (640, 640))
    outs = run_ort(args.det, to_input(lb))
    objs = dc._decode_heads(outs, 0.25, keep_cls=[0])
    objs = dc._post(objs, 0.45, max_det=64)
    print('stage1 raw objs=%d' % len(objs))
    boxes = []
    for o in objs:
        b = dc.TwoStageDetector._map_back(o.box, scale, px, py, W, H)
        boxes.append(b)
        print('  person (%d %d %d %d) %.3f' % (b[0], b[1], b[2], b[3], o.score))
    assert boxes, 'stage1 没解出任何人体框'

    # ---------------- Stage 2
    vis = img.copy()
    for i, b in enumerate(boxes[:3]):
        x1, y1, x2, y2 = [int(v) for v in b]
        roi = img[y1:y2, x1:x2]
        rlb, rs, rpx, rpy = dc.letterbox(roi, (640, 640))
        ro = run_ort(args.pose, to_input(rlb))
        pods = dc._decode_heads(ro, 0.25, keep_cls=[0], want_kps=True)
        pods = dc._post(pods, 0.45, max_det=1)
        assert pods and pods[0].kps is not None, 'stage2 没解出关键点'
        k = pods[0].kps.astype(np.float32)
        k[:, 0] = (k[:, 0] - rpx) / rs + x1
        k[:, 1] = (k[:, 1] - rpy) / rs + y1
        good = int((k[:, 2] > 0.3).sum())
        print('  roi#%d keypoints good=%d/17  nose=(%.0f,%.0f,%.2f)'
              % (i, good, k[0][0], k[0][1], k[0][2]))
        assert good >= 8, '关键点数量太少(%d)，解码可能有问题' % good
        for a, bb in dc.SKELETON:
            if k[a][2] > 0.3 and k[bb][2] > 0.3:
                cv2.line(vis, (int(k[a][0]), int(k[a][1])),
                         (int(k[bb][0]), int(k[bb][1])), (0, 200, 255), 2, cv2.LINE_AA)
        for j in range(17):
            if k[j][2] > 0.3:
                cv2.circle(vis, (int(k[j][0]), int(k[j][1])), 3, (0, 0, 255), -1, cv2.LINE_AA)
    for b in boxes:
        cv2.rectangle(vis, (int(b[0]), int(b[1])), (int(b[2]), int(b[3])), (0, 255, 0), 2)
    cv2.imwrite('test_det_core.jpg', vis)
    print('OK —— 结果图 test_det_core.jpg')


if __name__ == '__main__':
    main()
