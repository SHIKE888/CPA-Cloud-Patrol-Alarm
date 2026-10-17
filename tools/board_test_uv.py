import sys
import numpy as np
import cv2

sys.path.insert(0, "/root/rk/web")
import mipi_webstream as m

w, h = 1920, 1080
buf = np.fromfile("/tmp/raw1080.nv16", np.uint8)
print("size", buf.size, "expect", w * h * 2)
for sw in (False, True):
    img = m.yuv_to_bgr_c(buf, w, h, fmt="NV16", matrix="709",
                         rng="limited", swap_uv=sw, nthreads=4)
    print("swap", sw, None if img is None else img.shape)
    if img is not None:
        cv2.imwrite("/tmp/raw1080_sw%d.jpg" % int(sw), img,
                    [cv2.IMWRITE_JPEG_QUALITY, 92])
