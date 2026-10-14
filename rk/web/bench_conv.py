#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_conv.py —— 验证「分条并行色彩转换」能否线性扩展

已知 (A72 单核):
  cap.read()       16.8 ms  (59.6 fps)  <- 链路上限, 已达标
  yuv_to_bgr 1080p 67.2 ms              <- 真正瓶颈
  yuv_to_bgr  720p 35.5 ms
  imencode   1080p 18.2 ms (线程池 4 线程 3.72x)
  imencode    720p  8.1 ms

思路: yuv_to_bgr 是按行独立的, 把画面切成 N 条水平带用 N 个线程同时转
      (cv2/numpy 的大数组运算会释放 GIL)。算法本身一字不改, 所以颜色不会变。

本脚本:
  1. 对比单线程 vs 分条并行的耗时
  2. 逐像素校验分条结果与单线程结果一致

用法:
  taskset -c 4-7 /opt/miniforge3/envs/mlk-ov/bin/python bench_conv.py
"""
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import cv2

W, H = 1920, 1080
N = 30

_YUV_LUT_CACHE = {}
# BT.709: 与 mipi_webstream.py 的 YUV_MATRIX 一致
YUV_MATRIX = {"709": (0.2126, -0.1146, -0.5000, 1.8556)}


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
        yv, c = i, i - 128.0
    lut = (np.rint(yv).astype(np.int16), np.rint(kb * c).astype(np.int16),
           np.rint(kgu * c).astype(np.int16), np.rint(kgv * c).astype(np.int16),
           np.rint(kr * c).astype(np.int16))
    _YUV_LUT_CACHE[key] = lut
    return lut


def conv_chunk(y, c, alloc):
    """把一条水平带 (Y: h x w uint8, c: h x (w/2) x 2 uint8) 转成 BGR 返回"""
    h, w = y.shape
    luty, lutb, lutgu, lutgv, lutr = _yuv_luts()
    yv = cv2.LUT(y, luty).reshape(h, w // 2, 2)
    uu, vv = cv2.split(c)
    gsum = cv2.LUT(uu, lutgu)
    gsum += cv2.LUT(vv, lutgv)
    b = yv + cv2.LUT(uu, lutb)[:, :, None]
    g = yv + gsum[:, :, None]
    r = yv + cv2.LUT(vv, lutr)[:, :, None]
    out = alloc
    for i, ch in enumerate((b, g, r)):
        np.clip(ch, 0, 255, out=ch)
        out[..., i] = ch
    return out.reshape(h, w, 3)


def yuv_to_bgr_serial(y, c):
    h, w = y.shape
    return conv_chunk(y, c, np.empty((h, w // 2, 2, 3), np.uint8))


def yuv_to_bgr_striped(y, c, nthreads, pool):
    h, w = y.shape
    rows = [(i * h) // nthreads for i in range(nthreads + 1)]
    outs = [np.empty((rows[i + 1] - rows[i], w // 2, 2, 3), np.uint8)
            for i in range(nthreads)]
    futs = [pool.submit(conv_chunk, y[rows[i]:rows[i + 1]],
                        np.ascontiguousarray(c[rows[i]:rows[i + 1]]), outs[i])
            for i in range(nthreads)]
    bgr = np.empty((h, w, 3), np.uint8)
    for i, f in enumerate(futs):
        bgr[rows[i]:rows[i + 1]] = f.result()
    return bgr


def timeit(label, fn, n=N):
    fn()
    t0 = time.time()
    for _ in range(n):
        r = fn()
    dt = (time.time() - t0) / n * 1000
    print("  %-44s %7.2f ms  -> %6.1f fps" % (label, dt, 1000.0 / dt))
    return dt, r


def main():
    print("cv2 %s, 可用核 %s" % (cv2.__version__, sorted(__import__("os").sched_getaffinity(0))))

    rng = np.random.default_rng(7)
    y = rng.integers(16, 236, (H, W), dtype=np.uint8)
    c = rng.integers(0, 256, (H, W // 2, 2), dtype=np.uint8)

    print("\n=== 色彩转换: 单线程 vs 分条并行 (1920x1080) ===")
    t1, ref = timeit("单线程", lambda: yuv_to_bgr_serial(y, c))

    with ThreadPoolExecutor(4) as pool:
        for k in (2, 3, 4):
            t, got = timeit("%d 线程分条" % k,
                            lambda k=k: yuv_to_bgr_striped(y, c, k, pool))
            diff = int(np.abs(got.astype(np.int16) - ref.astype(np.int16)).max())
            print("                 加速比 %.2fx, 与单线程最大差 %d (应=0)"
                  % (t1 / t, diff))

    print("\n=== 720 目标尺寸也一样 ===")
    y7 = cv2.resize(y, (1280, 720), interpolation=cv2.INTER_AREA)
    c7 = cv2.resize(c, (640, 720), interpolation=cv2.INTER_AREA)
    t1b, ref7 = timeit("单线程 (1280x720)", lambda: yuv_to_bgr_serial(y7, c7))
    with ThreadPoolExecutor(4) as pool:
        t4b, got7 = timeit("4 线程分条 (1280x720)",
                           lambda: yuv_to_bgr_striped(y7, c7, 4, pool))
        print("                 加速比 %.2fx, 最大差 %d"
              % (t1b / t4b,
                 int(np.abs(got7.astype(np.int16) - ref7.astype(np.int16)).max())))

    print("\n=== 加上缩放 (YUV 域预缩放到 720p) 的总耗时 ===")

    def make720():
        ys = cv2.resize(y, (1280, 720), interpolation=cv2.INTER_AREA)
        cs = cv2.resize(c, (640, 720), interpolation=cv2.INTER_AREA)
        return ys, cs

    t_res, _ = timeit("cv2.resize 1920x1080 -> 1280x720 (Y+C)", make720, 20)
    with ThreadPoolExecutor(4) as pool:
        def full720():
            ys, cs = make720()
            return yuv_to_bgr_striped(ys, cs, 4, pool)
        t_full, _ = timeit("resize + 4 线程转换", full720, 20)
    print("                 => 720p 转换全流程 %.2f ms" % t_full)
    return 0


if __name__ == "__main__":
    sys.exit(main())
