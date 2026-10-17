import sys
import time

import numpy as np

sys.path.insert(0, "/root/rk/web")
import mipi_webstream as M  # noqa: E402

cv2 = M.cv2
W, H = 3840, 2160
buf = np.fromfile("/tmp/raw4k.nv16", np.uint8)
wh = W * H
raw = buf[: wh * 2]
y = raw[:wh].reshape(H, W)
c = raw[wh:wh * 2].reshape(H, W // 2, 2)

# 造一份 1080p NV16 供对照
y1 = cv2.resize(y, (1920, 1080), interpolation=cv2.INTER_AREA)
c1 = cv2.resize(c, (960, 1080), interpolation=cv2.INTER_AREA)
np.concatenate([y1.reshape(-1), c1.reshape(-1)]).tofile("/tmp/t1080.nv16")

print("cv2 threads:", cv2.getNumThreads())


def t(fn, n=10):
    fn()
    t0 = time.time()
    for _ in range(n):
        fn()
    return (time.time() - t0) / n * 1e3


def run(label, sw, sh, ysrc, csrc):
    dy = np.empty((sh, sw), np.uint8)
    for name, interp in (("AREA", cv2.INTER_AREA),
                         ("LINEAR", cv2.INTER_LINEAR),
                         ("NEAREST", cv2.INTER_NEAREST)):
        a = t(lambda: cv2.resize(ysrc, (sw, sh), dst=dy, interpolation=interp))
        b = t(lambda: cv2.resize(csrc, (sw // 2, sh), interpolation=interp))
        print("  %-8s Y %6.1fms  C %6.1fms  sum %6.1fms" % (name, a, b, a + b))


print("3840x2160 -> 1728x972")
run("4k", 1728, 972, y, c)
print("1920x1080 -> 1728x972")
run("1080", 1728, 972, y1, c1)

# 转 + 编码单独计时
tw, th = 1728, 972
stage = np.empty(tw * th * 2, np.uint8)
ys = cv2.resize(y, (tw, th), interpolation=cv2.INTER_AREA)
cs = cv2.resize(c, (tw // 2, th), interpolation=cv2.INTER_AREA)
stage[: tw * th] = ys.reshape(-1)
stage[tw * th:] = cs.reshape(-1)
print("conv  %6.1fms" % t(lambda: M.yuv_to_bgr_c(stage, tw, th, fmt="NV16",
                                                 matrix="709", rng="limited",
                                                 swap_uv=False, nthreads=4)))
bgr = M.yuv_to_bgr_c(stage, tw, th, fmt="NV16", matrix="709",
                     rng="limited", swap_uv=False, nthreads=4)
print("jpeg  %6.1fms" % t(lambda: cv2.imencode(".jpg", bgr,
                                              [int(cv2.IMWRITE_JPEG_QUALITY), 80])))
