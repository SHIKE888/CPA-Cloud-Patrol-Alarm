import sys
import time

import numpy as np

sys.path.insert(0, "/root/rk/web")
import mipi_webstream as M  # noqa: E402

print("cv2", M.cv2.__version__, "numpy", np.__version__)


def bench(path, w, h, stream_w, scale=0.9, quality=80, n=30):
    buf = np.fromfile(path, np.uint8)
    wh = w * h
    raw = buf[: wh * 2]
    tw = max(64, int(round(stream_w * scale / 2.0) * 2))
    th = max(64, int(round(tw * h / float(w) / 2.0) * 2))
    stage = np.empty(tw * th * 2, np.uint8)
    y = raw[:wh].reshape(h, w)
    c = raw[wh:wh * 2].reshape(h, w // 2, 2)

    # 1) YUV 域缩放
    t = time.time()
    for _ in range(n):
        ys = M.cv2.resize(y, (tw, th), interpolation=M.cv2.INTER_AREA)
        cs = M.cv2.resize(c, (max(1, tw // 2), th), interpolation=M.cv2.INTER_AREA)
        stage[: tw * th] = ys.reshape(-1)
        stage[tw * th:] = cs.reshape(-1)
    t_scale = (time.time() - t) / n

    # 2) YUV -> BGR
    t = time.time()
    for _ in range(n):
        bgr = M.yuv_to_bgr_c(stage, tw, th, fmt="NV16",
                             matrix="709", rng="limited", swap_uv=False, nthreads=4)
    t_conv = (time.time() - t) / n

    # 3) JPEG
    t = time.time()
    for _ in range(n):
        ok, jb = M.cv2.imencode(".jpg", bgr, [int(M.cv2.IMWRITE_JPEG_QUALITY), quality])
    t_enc = (time.time() - t) / n
    total = t_scale + t_conv + t_enc
    print("%4dx%-4d -> %4dx%-4d  scale %.1fms  conv %.1fms  enc %.1fms  = %.1fms  => %.1f fps  (jpeg %dKB)"
          % (w, h, tw, th, t_scale * 1e3, t_conv * 1e3, t_enc * 1e3,
             total * 1e3, 1.0 / total, len(jb) // 1024))


bench("/tmp/raw4k.nv16", 3840, 2160, 1920, 0.9, 80)
bench("/tmp/t1080.nv16", 1920, 1080, 1920, 0.9, 80)
