#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_pipeline.py —— OpenCV 后端各段耗时 + 线程池扩展性

为「1080p60 MJPEG」定方案: 先量准 cap.read / yuv_to_bgr / imencode
各自多少 ms, 再决定把哪一段并行化。

用法:
  pkill -f 'mipi_web[s]tream'
  taskset -c 4-7 /opt/miniforge3/envs/mlk-ov/bin/python bench_pipeline.py [/dev/video22]
"""
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import cv2

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/video22"
W, H = 1920, 1080
N = 60

_YUV_LUT_CACHE = {}
YUV_MATRIX = {"709": (0.2126, -0.1146, -0.5000, 1.8556)}

# 与 mipi_webstream.py 完全相同的查表实现
def _yuv_luts(matrix="709", rng="limited"):
    key = (matrix, rng)
    if key in _YUV_LUT_CACHE:
        return _YUV_LUT_CACHE[key]
    kr, kgu, kgv, kb = YUV_MATRIX.get(matrix, YUV_MATRIX["709"])
    i = np.arange(256, dtype=np.float32)
    if rng == "limited":
        yv = np.clip((i - 16.0) * (255.0 / 219.0), 0.0, 255.0)
        c = (i - 128.0) * (255.0 / 224.0)
    else:
        yv = i
        c = i - 128.0
    lut = (np.rint(yv).astype(np.int16), np.rint(kb * c).astype(np.int16),
           np.rint(kgu * c).astype(np.int16), np.rint(kgv * c).astype(np.int16),
           np.rint(kr * c).astype(np.int16))
    _YUV_LUT_CACHE[key] = lut
    return lut


def yuv_to_bgr(buf, w, h, target=None):
    n = w * h
    y = buf[:n].reshape(h, w)
    c = buf[n:n + n].reshape(h, w // 2, 2)
    if target and (target[0] != w or target[1] != h):
        tw, th = int(target[0]), int(target[1])
        y = cv2.resize(y, (tw, th), interpolation=cv2.INTER_AREA)
        c = cv2.resize(c, (max(1, tw // 2), th), interpolation=cv2.INTER_AREA)
        w, h = tw, th
    luty, lutb, lutgu, lutgv, lutr = _yuv_luts()
    yv = cv2.LUT(y, luty).reshape(h, w // 2, 2)
    uu, vv = cv2.split(c)
    gsum = cv2.LUT(uu, lutgu)
    gsum += cv2.LUT(vv, lutgv)
    b = yv + cv2.LUT(uu, lutb)[:, :, None]
    g = yv + gsum[:, :, None]
    r = yv + cv2.LUT(vv, lutr)[:, :, None]
    out = np.empty((h, w // 2, 2, 3), np.uint8)
    for i, ch in enumerate((b, g, r)):
        np.clip(ch, 0, 255, out=ch)
        out[..., i] = ch
    return out.reshape(h, w, 3)


def timeit(label, fn, n=N):
    fn()                                     # 预热
    t0 = time.time()
    r = None
    for _ in range(n):
        r = fn()
    dt = (time.time() - t0) / n * 1000
    print("  %-42s %7.2f ms   -> %5.1f fps" % (label, dt, 1000.0 / dt))
    return dt, r


def main():
    print("cv2 %s, 线程数 %d, 亲和性 %s"
          % (cv2.__version__, os.cpu_count(), sorted(os.sched_getaffinity(0))))

    cap = cv2.VideoCapture(DEV, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"NV16"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
    try:
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 4)
    except Exception:
        pass
    if not cap.isOpened():
        print("打不开 %s" % DEV); return 1
    for _ in range(10):
        ok, f = cap.read()
    if not ok:
        print("读帧失败"); return 1
    aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print("分辨率 %dx%d, 每帧 %d 字节\n" % (aw, ah, f.size))
    if f.ndim == 3:
        print("注意: 拿到的是已转换的 3 通道图, 不是原始 YUV")
        return 1

    raw = f.reshape(-1)
    print("=== 各段单独耗时 ===")
    t_read, _ = timeit("cap.read()  (取一帧原始 NV16)", lambda: cap.read())
    t_cv1080, bgr1080 = timeit("yuv_to_bgr  (1920x1080)", lambda: yuv_to_bgr(raw, W, H))
    t_cv720, bgr720 = timeit("yuv_to_bgr  (预缩放到 1280x720)",
                             lambda: yuv_to_bgr(raw, W, H, target=(1280, 720)))
    t_cv540, _ = timeit("yuv_to_bgr  (预缩放到 960x540)",
                        lambda: yuv_to_bgr(raw, W, H, target=(960, 540)))

    enc = [int(cv2.IMWRITE_JPEG_QUALITY), 80]
    t_e1080, _ = timeit("imencode    (1920x1080 q80)", lambda: cv2.imencode(".jpg", bgr1080, enc), 40)
    t_e720, _ = timeit("imencode    (1280x720  q80)", lambda: cv2.imencode(".jpg", bgr720, enc), 40)
    ok, buf = cv2.imencode(".jpg", bgr720, enc)
    print("              720p JPEG 大小 %.0f KB" % (len(buf) / 1024.0))

    print("\n=== 串行相加 (= 现在 OpenCV 后端的行为) ===")
    for name, tc, te in (("1080p", t_cv1080, t_e1080), ("720p", t_cv720, t_e720)):
        tot = t_read + tc + te
        print("  %-8s read %.1f + conv %.1f + enc %.1f = %.1f ms -> %.1f fps"
              % (name, t_read, tc, te, tot, 1000.0 / tot))

    print("\n=== 三级流水线 (取最长一段) ===")
    for name, tc, te in (("1080p", t_cv1080, t_e1080), ("720p", t_cv720, t_e720)):
        stage = max(t_read, tc, te)
        print("  %-8s max(read %.1f, conv %.1f, enc %.1f) = %.1f ms -> %.1f fps"
              % (name, t_read, tc, te, stage, 1000.0 / stage))

    print("\n=== imencode 线程池扩展性 (Python 线程, cv2 会释放 GIL) ===")
    base = None
    for k in (1, 2, 3, 4):
        with ThreadPoolExecutor(k) as ex:
            ex.submit(lambda: cv2.imencode(".jpg", bgr720, enc)).result()
            t0 = time.time()
            list(ex.map(lambda _: cv2.imencode(".jpg", bgr720, enc), range(k * 20)))
            dt = time.time() - t0
        agg = k * 20 / dt
        if base is None:
            base = agg
        print("  %d 线程: 聚合 %6.1f fps  加速比 %.2fx" % (k, agg, agg / base))

    print("\n=== 结论 ===")
    stage = max(t_read, t_cv720, t_e720)
    print("  720p 三级流水线上限 %.1f fps; 1080p 上限 %.1f fps"
          % (1000.0 / max(t_read, t_cv720, t_e720), 1000.0 / max(t_read, t_cv1080, t_e1080)))
    cap.release()
    return 0


if __name__ == "__main__":
    sys.exit(main())
