#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_onnx.py —— 在 x86 上用 onnxruntime 验证后处理解码逻辑。

用途：转换前先确认 airockchip 版 ONNX 的输出布局与解码公式是否正确，
      并产出可视化结果（det.jpg / pose.jpg）供核对。

用法：python verify_onnx.py <image> [--det yolov8n.onnx] [--pose yolov8n-pose.onnx]
"""
from __future__ import annotations

import argparse
import os
import sys

import cv2
import numpy as np


def letterbox(img, size=(640, 640), color=114):
    h, w = img.shape[:2]
    tw, th = size
    r = min(tw / float(w), th / float(h))
    nw, nh = int(round(w * r)), int(round(h * r))
    resized = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((th, tw, 3), color, dtype=img.dtype)
    px, py = (tw - nw) // 2, (th - nh) // 2
    canvas[py:py + nh, px:px + nw] = resized
    return canvas, r, px, py


def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def decode(outputs, conf_thres=0.25, keep_cls=None, want_kps=False):
    """自适应解析两种 yolov8 导出布局：

      A) 分离式（yolov8n.onnx）：每 stride 输出 DFL(64ch) + 类别(80ch, 已 sigmoid) + aux(1ch)
      B) 合并式（yolov8n-pose.onnx）：每 stride 输出 (64+ncls)ch，cls 为 logits（未 sigmoid）
    统一规则：同一 H 下若有 64ch 张量，则该组为分离式；否则把 >64ch 的张量拆成 DFL+cls。
    """
    groups = {}
    kps_out = None
    aux = []
    for o in outputs:
        # 关键点输出：(1,17,3,8400) 或 (1,51,8400)
        if o.ndim == 4 and o.shape[1] == 17 and o.shape[2] == 3:
            kps_out = o.reshape(51, -1)
            print('  [kps out] %s -> %s' % (o.shape, kps_out.shape))
            continue
        if o.ndim == 4:
            groups.setdefault(o.shape[2], []).append(o[0])
        elif o.ndim == 3 and o.shape[1] in (17, 51) and o.shape[-1] >= 100:
            kps_out = o.reshape(51, -1)
            print('  [kps out] %s -> %s' % (o.shape, kps_out.shape))
    for H, arrs in sorted(groups.items()):
        for a in arrs:
            if a.shape[0] == 1:
                aux.append((H, float(a.min()), float(a.max())))
    for H, mn, mx in aux:
        print('  [aux out] 1x%dx%d min=%.4f max=%.4f' % (H, H, mn, mx))

    objs = []
    offset = 0
    for H in sorted(groups.keys(), reverse=True):      # stride8(80) -> 16(40) -> 32(20)
        arrs = groups[H]
        stride = 640.0 / H
        merged = None
        dfl = cls = None
        for a in arrs:
            if a.shape[0] == 64:
                dfl = a
        if dfl is not None:
            for a in arrs:
                if a.shape[0] != 64:
                    cls = a
                    break
        else:
            for a in arrs:
                if a.shape[0] > 64:
                    merged = a
                    dfl, cls = a[:64], a[64:]
                    break
        if dfl is None or cls is None:
            offset += H * H
            continue

        lo, hi = float(cls.min()), float(cls.max())
        if 0.0 <= lo and hi <= 1.0:
            conf = cls
            kind = 'already-sigmoid'
        else:
            conf = sigmoid(cls)
            kind = 'logits->sigmoid'
        print('  [head] H=%d(%s) stride=%d cls=%dch range=(%.3f,%.3f) %s'
              % (H, 'merged' if merged is not None else 'split', stride, cls.shape[0], lo, hi, kind))

        if keep_cls is not None:
            conf = conf[keep_cls]
        hits = np.argwhere(conf > conf_thres)
        if hits.size:
            c, y, x = hits[:, 0], hits[:, 1], hits[:, 2]
            sc = conf[c, y, x]
            dist = dfl.reshape(4, 16, H, H)[:, :, y, x]
            dist = dist - dist.max(axis=1, keepdims=True)
            e = np.exp(dist)
            e /= e.sum(axis=1, keepdims=True)
            ltrb = (e * np.arange(16, dtype=np.float32).reshape(1, 16, 1)).sum(axis=1)
            cx = (x + 0.5) * stride
            cy = (y + 0.5) * stride
            boxes = np.stack([cx - ltrb[0] * stride, cy - ltrb[1] * stride,
                              cx + ltrb[2] * stride, cy + ltrb[3] * stride], axis=1)
            kp = None
            if kps_out is not None:
                anchor = offset + y * H + x
                kp = kps_out[:, anchor].reshape(17, 3, -1)
            for i in range(boxes.shape[0]):
                objs.append({'box': boxes[i].astype(np.float32), 'score': float(sc[i]),
                             'cls': int(c[i]), 'kps': kp[:, :, i].copy() if kp is not None else None})
        offset += H * H

    if not objs:
        return []
    order = np.argsort(-np.array([o['score'] for o in objs]))
    objs = [objs[int(i)] for i in order]
    out = []
    for o in objs:
        if any(_iou(o['box'], k['box']) > 0.45 and o['cls'] == k['cls'] for k in out):
            continue
        out.append(o)
    return out


def _iou(a, b):
    x1, y1 = max(a[0], b[0]), max(a[1], b[1])
    x2, y2 = min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / max(1e-9, ua)


SKELETON = [(15, 13), (13, 11), (16, 14), (14, 12), (11, 12), (5, 11), (6, 12),
            (5, 6), (5, 7), (6, 8), (7, 9), (8, 10), (1, 2), (0, 1), (0, 2),
            (1, 3), (2, 4), (3, 5), (4, 6)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('--det', default='yolov8n.onnx')
    ap.add_argument('--pose', default='yolov8n-pose.onnx')
    ap.add_argument('--out', default='.')
    args = ap.parse_args()

    import onnxruntime as ort

    img = cv2.imread(args.image)
    if img is None:
        sys.exit('读不到图片 %s' % args.image)
    H, W = img.shape[:2]
    print('image %s  %dx%d' % (args.image, W, H))

    lb, scale, px, py = letterbox(img, (640, 640))
    inp = lb[:, :, ::-1].astype(np.float32) / 255.0            # RGB, 0~1
    inp = np.ascontiguousarray(inp.transpose(2, 0, 1)[None])   # NCHW

    # ---------------- Stage 1: 人体检测
    print('=== stage1 detection: %s' % args.det)
    s1 = ort.InferenceSession(args.det, providers=['CPUExecutionProvider'])
    names = [o.name for o in s1.get_outputs()]
    print('  outputs:', [(o.name, o.shape) for o in s1.get_outputs()])
    outs = s1.run(None, {s1.get_inputs()[0].name: inp})
    dets = decode(outs, 0.25, keep_cls=[0])
    vis = img.copy()
    persons = []
    for d in dets:
        b = d['box']
        x1 = int((b[0] - px) / scale)
        y1 = int((b[1] - py) / scale)
        x2 = int((b[2] - px) / scale)
        y2 = int((b[3] - py) / scale)
        x1, y1 = max(0, x1), max(0, y1)
        x2, y2 = min(W - 1, x2), min(H - 1, y2)
        persons.append((x1, y1, x2, y2))
        print('  person (%d %d %d %d)  %.3f' % (x1, y1, x2, y2, d['score']))
        cv2.rectangle(vis, (x1, y1), (x2, y2), (0, 255, 0), 2)
        cv2.putText(vis, 'person %.2f' % d['score'], (x1, max(12, y1 - 5)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1, cv2.LINE_AA)
    cv2.imwrite(os.path.join(args.out, 'verify_det.jpg'), vis)

    # ---------------- Stage 2: 姿态
    print('=== stage2 pose: %s' % args.pose)
    s2 = ort.InferenceSession(args.pose, providers=['CPUExecutionProvider'])
    print('  outputs:', [(o.name, o.shape) for o in s2.get_outputs()])
    for i, (x1, y1, x2, y2) in enumerate(persons[:3]):
        ex = 1.15
        cx, cy = (x1 + x2) / 2.0, (y1 + y2) / 2.0
        rw, rh = (x2 - x1) * ex, (y2 - y1) * ex
        rx1, ry1 = int(max(0, cx - rw / 2)), int(max(0, cy - rh / 2))
        rx2, ry2 = int(min(W, cx + rw / 2)), int(min(H, cy + rh / 2))
        roi = img[ry1:ry2, rx1:rx2]
        if roi.size == 0:
            continue
        rlb, rscale, rpx, rpy = letterbox(roi, (640, 640))
        rin = rlb[:, :, ::-1].astype(np.float32) / 255.0
        rin = np.ascontiguousarray(rin.transpose(2, 0, 1)[None])
        ro = s2.run(None, {s2.get_inputs()[0].name: rin})
        pods = decode(ro, 0.25, keep_cls=[0], want_kps=True)
        print('  roi#%d persons=%d' % (i, len(pods)))
        if not pods or pods[0]['kps'] is None:
            continue
        k = pods[0]['kps'].astype(np.float32)
        print('  RAW kps  x=[%.1f,%.1f] y=[%.1f,%.1f] conf=[%.2f,%.2f]'
              % (k[:, 0].min(), k[:, 0].max(), k[:, 1].min(), k[:, 1].max(),
                 k[:, 2].min(), k[:, 2].max()))
        print('  RAW kps[:4]:', np.round(k[:4], 2).tolist())
        k[:, 0] = (k[:, 0] - rpx) / rscale + rx1
        k[:, 1] = (k[:, 1] - rpy) / rscale + ry1
        good = int((k[:, 2] > 0.3).sum())
        print('  keypoints(good=%d/17):' % good,
              ['%.0f,%.0f,%.2f' % (a, b, c) for a, b, c in k[:5]])
        for a, b in SKELETON:
            if k[a][2] > 0.3 and k[b][2] > 0.3:
                cv2.line(vis, (int(k[a][0]), int(k[a][1])), (int(k[b][0]), int(k[b][1])),
                         (0, 200, 255), 2, cv2.LINE_AA)
        for j in range(17):
            if k[j][2] > 0.3:
                cv2.circle(vis, (int(k[j][0]), int(k[j][1])), 3, (0, 0, 255), -1, cv2.LINE_AA)
    cv2.imwrite(os.path.join(args.out, 'verify_pose.jpg'), vis)
    print('saved: verify_det.jpg / verify_pose.jpg')


if __name__ == '__main__':
    main()
