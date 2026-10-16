#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""board_smoke.py —— 板上 NPU 冒烟测试：采一帧 → 两级推理 → 输出形状/耗时/结果图。

用法（板上）：python3 board_smoke.py [/dev/video22]
"""
from __future__ import annotations

import os
import sys
import time

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
AI = '/root/rk/ai'
sys.path.insert(0, os.path.join(AI, 'board'))
sys.path.insert(0, HERE)

import det_core as dc  # noqa: E402


def grab(dev, n=10):
    if os.path.isfile(dev):
        return cv2.imread(dev), None
    if dev.split('://')[0] in ('http', 'https', 'rtsp', 'rtmp'):
        cap = cv2.VideoCapture(dev)
    else:
        cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
        if not cap.isOpened():
            cap = cv2.VideoCapture(dev)
    if not cap.isOpened():
        return None, None
    if dev.split('://')[0] not in ('http', 'https', 'rtsp', 'rtmp'):
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    frame = None
    for _ in range(n):
        ok, f = cap.read()
        if ok and f is not None:
            frame = f
    cap.release()
    return frame, None


def main():
    dev = sys.argv[1] if len(sys.argv) > 1 else '/dev/video22'
    pose_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(AI, 'models', 'yolov8n-pose.rknn')
    t0 = time.time()
    frame, _ = grab(dev)
    if frame is None:
        print('!! 采集 %s 失败' % dev)
        sys.exit(1)
    dt = (time.time() - t0) * 1000
    print('采集成功 %s  shape=%s  (%.0f ms)' % (dev, frame.shape, dt))
    cv2.imwrite('/root/rk/ai/test_frame.jpg', frame)

    det = dc.TwoStageDetector(os.path.join(AI, 'models', 'yolov8n.rknn'),
                              pose_path)
    print('模型 det: ok=%s err=%s' % (det.det.ok, det.det.err))
    print('模型 pose: ok=%s err=%s' % (det.pose.ok, det.pose.err))
    if not det.det.ok:
        sys.exit('检测模型未就绪')

    lb, _, _, _ = dc.letterbox(frame, (640, 640))
    rgb = np.ascontiguousarray(lb[:, :, ::-1])
    o1 = det.det.infer(rgb)
    print('det  outputs:', [tuple(o.shape) for o in o1], 'dtype', o1[0].dtype)
    if det.pose.ok:
        o2 = det.pose.infer(rgb)
        print('pose outputs:', [tuple(o.shape) for o in o2])

    t0 = time.time()
    dets = det.run(frame)
    print('两级一次: %.1f ms  (det %.1f + pose %.1f)  -> %d 人'
          % ((time.time() - t0) * 1000, det.stat['det_ms'], det.stat['pose_ms'], len(dets)))

    vis = frame.copy()
    for d in dets:
        kps = d['kps']
        good = int((kps[:, 2] > 0.3).sum()) if kps is not None else 0
        print('   box=%s score=%.3f kpts=%d/17'
              % ([int(v) for v in d['box']], d['score'], good))
        dc.draw_person(vis, d['box'], d['score'], 'person', (0, 255, 0), 2, kps=kps)
    cv2.imwrite('/root/rk/ai/test_out.jpg', vis)

    # 姿态置信度诊断：绕过阈值看原始 conf（判断量化是否伤到关键点分支）
    if dets and det.pose.ok:
        keep = det.kpt_conf
        det.kpt_conf = 0.0
        k0 = det.pose_in(frame, dets[0]['box'])
        det.kpt_conf = keep
        if k0 is not None:
            print('   raw kpt conf:', [round(float(v), 3) for v in k0[:, 2]])
            print('   raw kpt xy  :', [[round(float(a)), round(float(b))]
                                       for a, b, c in k0[:5]])
        else:
            print('   !! pose_in 返回 None（ROI 内没检到人或缺少关键点输出）')

    n = 20
    t0 = time.time()
    for _ in range(n):
        det.run(frame)
    el = time.time() - t0
    print('连续 %d 次: %.1f ms/帧 -> %.1f fps (两级串联上限)' % (n, el / n * 1000, n / el))
    print('结果图: /root/rk/ai/test_out.jpg')


if __name__ == '__main__':
    main()
