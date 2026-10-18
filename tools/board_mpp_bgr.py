"""直接喂 BGR 给 mppjpegenc —— 颜色会不会和 cv2 一致?"""
import subprocess
import sys

import cv2
import numpy as np

sys.path.insert(0, "/root/rk/web")
import mipi_webstream as M  # noqa: E402

SRC_W, SRC_H = 3840, 2160
TW, TH = 1728, 972

raw = np.fromfile("/tmp/raw4k.nv16", np.uint8)[: SRC_W * SRC_H * 2]
y = raw[: SRC_W * SRC_H].reshape(SRC_H, SRC_W)
c = raw[SRC_W * SRC_H:].reshape(SRC_H, SRC_W // 2, 2)
ys = cv2.resize(y, (TW, TH), interpolation=cv2.INTER_LINEAR)
cs = cv2.resize(c, (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
stage = np.concatenate([ys.reshape(-1), cs.reshape(-1)])
ref = M.yuv_to_bgr_c(stage, TW, TH, fmt="NV16", matrix="709",
                     rng="limited", swap_uv=False, nthreads=4)


def mpp_bgr(bgr, gst_fmt):
    fb = np.ascontiguousarray(bgr).tobytes()
    cmd = ["gst-launch-1.0", "-q",
           "fdsrc", "fd=0", "blocksize=%d" % len(fb), "!",
           "rawvideoparse", "format=%s" % gst_fmt,
           "width=%d" % TW, "height=%d" % TH, "!",
           "mppjpegenc", "!", "fdsink", "fd=1"]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, bufsize=0)
    out, _ = p.communicate(fb)
    s = out.find(b"\xff\xd8")
    e = out.find(b"\xff\xd9", s + 2)
    return out[s:e + 2] if s >= 0 and e > s else b""


def show(name, jpg):
    if not jpg:
        print(name, "FAIL")
        return
    dec = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
    d = np.abs(dec.astype(np.int16) - ref.astype(np.int16))
    print("%-24s %6dB mean|Δ| %5.2f p99 %3d mean=%s"
          % (name, len(jpg), d.mean(), int(np.percentile(d, 99)),
             np.round(dec.reshape(-1, 3).mean(axis=0), 1)))


print("参考 mean:", np.round(ref.reshape(-1, 3).mean(axis=0), 1))
show("cv2.imencode", cv2.imencode(".jpg", ref,
                                 [int(cv2.IMWRITE_JPEG_QUALITY), 80])[1].tobytes())
show("mpp BGR", mpp_bgr(ref, "bgr"))
show("mpp RGB(交换)", mpp_bgr(ref[:, :, ::-1], "rgb"))
