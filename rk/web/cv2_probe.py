#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cv2_probe.py —— 探测当前 Python 环境能否用 OpenCV/V4L2 打开采集节点。

用法:
    /opt/miniforge3/envs/mlk-ov/bin/python cv2_probe.py
    /opt/miniforge3/envs/mlk-ov/bin/python cv2_probe.py /dev/video22 /dev/video51
"""
import sys
import time

try:
    import cv2
    import numpy
except Exception as e:
    print("!! 依赖导入失败: %s" % e)
    sys.exit(1)

print("python : %s" % sys.version.split()[0])
print("exe    : %s" % sys.executable)
print("cv2    : %s" % cv2.__version__)
print("numpy  : %s" % numpy.__version__)

try:
    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst
    Gst.init(None)
    print("gi/Gst : OK")
except Exception as e:
    print("gi/Gst : -- %s" % e)

devs = sys.argv[1:] or ["/dev/video22", "/dev/video33", "/dev/video51"]

for dev in devs:
    print("\n--- %s ---" % dev)
    cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
    if not cap.isOpened():
        print("  isOpened 失败 (OpenCV 可能不支持该节点的 multiplanar 模式)")
        cap.release()
        continue
    print("  isOpened OK")
    print("  默认 FOURCC : %s" % int(cap.get(cv2.CAP_PROP_FOURCC)))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
    print("  协商后尺寸  : %dx%d" % (int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
                                     int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))))
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)

    t0 = time.time()
    got = 0
    shape = None
    while time.time() - t0 < 3.0:
        ret, frame = cap.read()
        if ret and frame is not None:
            got += 1
            shape = frame.shape
        else:
            time.sleep(0.01)
    dt = time.time() - t0
    print("  3 秒读到 %d 帧 (%.1f fps), shape=%s" % (got, got / dt, shape))
    cap.release()
