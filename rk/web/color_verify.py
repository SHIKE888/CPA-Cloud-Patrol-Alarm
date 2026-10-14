#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""color_verify.py —— 比较 GStreamer 输出 与 已知正确的转换结果

流程:
  1) v4l2-ctl 抓 1 帧原始 NV16 到 /tmp/ref.raw
  2) 用 mipi_webstream.yuv_to_bgr (BT.709 + limited) 转成参考图
  3) 读 GStreamer 出的 JPEG, 两者逐像素比对
     - 若均值差/RMS 很小 -> GStreamer 的 colorimetry 处理与我们一致(颜色正确)
     - 若差异大 -> GStreamer 用了别的 matrix/range

用法:
  pkill -f 'mipi_web[s]tream'
  /opt/miniforge3/envs/mlk-ov/bin/python color_verify.py [/dev/video22]
"""
import os
import subprocess
import sys

import numpy as np
import cv2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mipi_webstream import yuv_to_bgr          # noqa: E402

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/video22"
W, H, TW, TH = 1920, 1080, 1280, 720
RAW = "/tmp/ref.raw"
GST_JPEG = "/tmp/gsttest/ok_039.jpg"
OUT = "/tmp"


def grab_raw():
    if os.path.exists(RAW):
        os.remove(RAW)
    r = subprocess.run(
        ["v4l2-ctl", "-d", DEV,
         "--set-fmt-video=width=%d,height=%d,pixelformat=NV16" % (W, H),
         "--stream-mmap", "--stream-count=1", "--stream-to=" + RAW],
        capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(RAW):
        print("抓原始帧失败:", (r.stderr or r.stdout).strip())
        return None
    return np.fromfile(RAW, dtype=np.uint8)


def main():
    raw = grab_raw()
    if raw is None:
        return 1
    print("原始帧: %d 字节" % raw.size)

    ref = yuv_to_bgr(raw, W, H, fmt="NV16", matrix="709", rng="limited",
                     target=(TW, TH))
    cv2.imwrite(os.path.join(OUT, "verify_ref.jpg"), ref)

    if not os.path.exists(GST_JPEG):
        print("缺少 %s, 请先跑 gst_tune_test.sh" % GST_JPEG)
        return 1
    gst = cv2.imread(GST_JPEG)
    print("参考图 %s  |  GStreamer 图 %s" % (ref.shape, None if gst is None
                                            else gst.shape))
    if gst is None or gst.shape != ref.shape:
        print("尺寸不一致, 无法逐像素比较")
        return 1

    d = gst.astype(np.int16) - ref.astype(np.int16)
    print()
    print("  ref  均值(BGR): %s" % np.round(ref.reshape(-1, 3).mean(0), 1))
    print("  gst  均值(BGR): %s" % np.round(gst.reshape(-1, 3).mean(0), 1))
    print("  差值 均值(BGR): %s" % np.round(d.reshape(-1, 3).mean(0), 2))
    print("  差值 RMS (BGR): %s"
          % np.round(np.sqrt((d.astype(np.float32) ** 2)
                             .reshape(-1, 3).mean(0)), 2))
    print()
    print("  判读: RMS 个位数 且 均值差 <3  -> 两者一致(GStreamer 颜色正确)")
    print("        RMS 十几以上               -> GStreamer 矩阵/量程不同")

    side = np.hstack([ref, gst])
    cv2.imwrite(os.path.join(OUT, "verify_side.jpg"),
                cv2.resize(side, (1280, 360)))
    print("\n对比图: /tmp/verify_side.jpg (左=参考, 右=GStreamer)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
