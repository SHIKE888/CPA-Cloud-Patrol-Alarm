#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_yuvconv.py —— 校验 C 版 YUV->BGR 与 Python 版逐像素一致 + 测加速比

用法:
  ./build_yuvconv.sh
  taskset -c 4-7 /opt/miniforge3/envs/mlk-ov/bin/python test_yuvconv.py
"""
import ctypes
import os
import sys
import time

import numpy as np
import cv2

HERE = os.path.dirname(os.path.abspath(__file__))
SO = os.path.join(HERE, "libyuvconv.so")
W, H = 1920, 1080
N = 30

# 与 mipi_webstream.py 完全一致的系数
YUV_MATRIX = {
    "601": (1.402000, -0.344136, -0.714136, 1.772000),
    "709": (1.574800, -0.187300, -0.468100, 1.855600),
}
_LUT_CACHE = {}


def _yuv_luts(matrix="709", rng="limited"):
    key = (matrix, rng)
    if key in _LUT_CACHE:
        return _LUT_CACHE[key]
    kr, kgu, kgv, kb = YUV_MATRIX[matrix]
    i = np.arange(256, dtype=np.float32)
    if rng == "limited":
        yv = np.clip((i - 16.0) * (255.0 / 219.0), 0.0, 255.0)
        c = (i - 128.0) * (255.0 / 224.0)
    else:
        yv, c = i, i - 128.0
    lut = (np.rint(yv).astype(np.int16), np.rint(kb * c).astype(np.int16),
           np.rint(kgu * c).astype(np.int16), np.rint(kgv * c).astype(np.int16),
           np.rint(kr * c).astype(np.int16))
    _LUT_CACHE[key] = lut
    return lut


def yuv_to_bgr_numpy(buf, w, h, swap_uv=False):
    """与 mipi_webstream.yuv_to_bgr 相同的算法 (NV16, 不缩放)"""
    n = w * h
    y = buf[:n].reshape(h, w)
    c = buf[n:n + n].reshape(h, w // 2, 2)
    luty, lutb, lutgu, lutgv, lutr = _yuv_luts()
    yv = cv2.LUT(y, luty).reshape(h, w // 2, 2)
    uu, vv = cv2.split(c)
    if swap_uv:
        uu, vv = vv, uu
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


def load_lib():
    if not os.path.exists(SO):
        print("找不到 %s, 请先运行 ./build_yuvconv.sh" % SO)
        return None
    lib = ctypes.CDLL(SO)
    lib.yuvconv_nv16_to_bgr.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    lib.yuvconv_nv16_to_bgr.restype = ctypes.c_int
    lib.yuvconv_nv16_to_bgr_rows.argtypes = [
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
        ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.c_int, ctypes.c_int, ctypes.c_int]
    lib.yuvconv_nv16_to_bgr_rows.restype = ctypes.c_int
    lib.yuvconv_version.restype = ctypes.c_char_p
    return lib


def timeit(label, fn, n=N):
    fn()
    t0 = time.time()
    for _ in range(n):
        r = fn()
    dt = (time.time() - t0) / n * 1000
    print("  %-40s %7.2f ms  -> %6.1f fps" % (label, dt, 1000.0 / dt))
    return dt, r


def main():
    lib = load_lib()
    if lib is None:
        return 1
    print("库版本: %s" % lib.yuvconv_version().decode())

    rng = np.random.default_rng(11)
    src = rng.integers(0, 256, W * H * 2, dtype=np.uint8)
    # 让 Y 落在 limited 范围, 更贴近真实数据
    src[:W * H] = (rng.integers(16, 236, W * H)).astype(np.uint8)

    print("\n=== 正确性 (与 numpy 版逐像素比) ===")
    ref = yuv_to_bgr_numpy(src, W, H)
    for swap in (0, 1):
        dst = np.zeros((H, W, 3), np.uint8)
        rc = lib.yuvconv_nv16_to_bgr(src.ctypes.data_as(ctypes.c_char_p),
                                     dst.ctypes.data_as(ctypes.c_char_p),
                                     W, H, swap, 709, 0)
        r2 = yuv_to_bgr_numpy(src, W, H, swap_uv=bool(swap)) if swap else ref
        d = np.abs(dst.astype(np.int16) - r2.astype(np.int16))
        print("  swap_uv=%d  rc=%d  最大差 %d, 平均差 %.4f, 差>1 的像素 %.3f%%"
              % (swap, rc, d.max(), d.mean(), (d > 1).mean() * 100))

    print("\n=== 速度 ===")
    dst = np.zeros((H, W, 3), np.uint8)
    sp = src.ctypes.data_as(ctypes.c_char_p)
    dp = dst.ctypes.data_as(ctypes.c_char_p)
    t_np, _ = timeit("numpy/cv2 版 (1920x1080)", lambda: yuv_to_bgr_numpy(src, W, H), 20)
    t_c, _ = timeit("C 版 (1920x1080)",
                    lambda: lib.yuvconv_nv16_to_bgr(sp, dp, W, H, 0, 709, 0), 50)
    print("  => 加速 %.1fx" % (t_np / t_c))

    # ---- 行切分 + 多线程: C 函数按行独立, 切成几段并发调用。
    #      ctypes 调用期间会释放 GIL, 所以是真的并行。
    print("\n=== 行切分 + 多线程 ===")
    from concurrent.futures import ThreadPoolExecutor

    src_addr = src.ctypes.data
    uv_addr  = src_addr + W * H
    dst_addr = dst.ctypes.data

    def call_rows(r0, r1):
        return lib.yuvconv_nv16_to_bgr_rows(
            src_addr + r0 * W,        # Y 段起点
            uv_addr  + r0 * W,        # UV 段起点
            dst_addr + r0 * W * 3,    # 目标段起点
            W, r1 - r0, W, 0, 709, 0)

    def striped(nthreads):
        step = (H + nthreads - 1) // nthreads
        with ThreadPoolExecutor(nthreads) as pool:
            list(pool.map(lambda i: call_rows(i * step, min(H, (i + 1) * step)),
                          range(nthreads)))

    dst2 = np.zeros((H, W, 3), np.uint8)
    dst_backup, dst[:] = dst.copy(), 0
    striped(4)
    d = np.abs(dst.astype(np.int16) - ref.astype(np.int16))
    print("  4 线程分条结果 vs numpy 参考: 最大差 %d (应=0)" % d.max())
    dst[:] = dst_backup

    t4 = t_c
    for k in (1, 2, 4):
        t, _ = timeit("%d 线程分条 (1920x1080)" % k,
                      lambda k=k: striped(k), 30)
        if k == 4:
            t4 = t

    print("\n=== 结论 ===")
    print("  C 版单线程 %.2f ms, 4 线程分条 %.2f ms" % (t_c, t4))
    print("  采集一帧是 16.8ms, 所以转换必须 <16ms 才不拖后腿")
    print("  %s" % ("达标" if t4 < 16 else "还差 %.1f ms" % (t4 - 16)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
