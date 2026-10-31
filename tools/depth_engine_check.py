#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""depth_engine_check.py —— 用一张双目拼接快照离线跑"引擎本体"

和网页走同一条代码路径（stereo_depth.StereoDepth._compute），只是不经过
MJPEG/网络。用来在没有网页、或者要反复调参数时快速看效果。

用法(板上):
    /opt/miniforge3/envs/mlk-ov/bin/python depth_engine_check.py /tmp/dual_snap.jpg
"""
from __future__ import print_function

import base64
import struct
import sys

import cv2
import numpy as np

sys.path.insert(0, "/root/rk/web")
from stereo_depth import StereoDepth      # noqa: E402


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/dual_snap.jpg"
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    if img is None:
        raise SystemExit("读不到 %s" % path)
    h, w = img.shape[:2]
    if w < 2 * h:
        raise SystemExit("不是双目拼接 (%dx%d)" % (w, h))
    hw = w // 2
    L, R = img[:, :hw], img[:, hw:]

    eng = StereoDepth(None, quiet=True)
    res = None
    for _ in range(3):                     # 第 1 帧要测斜, 多跑两帧看稳定值
        res = eng._compute(L, R)
    if not res:
        raise SystemExit("没有产生点云（有效像素太少）")

    n = res["n"]
    raw = base64.b64decode(res["pts"])
    zs = sorted(struct.unpack_from("<h", raw, i * 9 + 4)[0] for i in range(n))
    q = lambda p: zs[min(n - 1, int(n * p))]
    print("点数 %d  有效像素 %.1f%%" % (n, res["valid"] * 100))
    print("输入斜移: 左 %.2f  右 %.2f  px/row（0 = 正常）"
          % (res["shear_l"], res["shear_r"]))
    print("z 2%%/50%%/98%% = %d / %d / %d mm" % (q(0.02), q(0.5), q(0.98)))
    print("focal %.0f px  fov %.0f°  处理 %dx%d  耗时 %.1f ms"
          % (res["focal_px"], res["fov_deg"], res["pw"], res["ph"],
             res.get("ms", 0)))


if __name__ == "__main__":
    sys.exit(main())
