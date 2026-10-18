"""A/B: cv2.imencode vs mppjpegenc, 看颜色偏差与码率。

参考 = yuv_to_bgr_c(BT.709 + limited) — 也就是现在网页上的颜色。
"""
import queue
import subprocess
import sys
import threading
import time

import cv2
import numpy as np

sys.path.insert(0, "/root/rk/web")
import mipi_webstream as M  # noqa: E402

SRC_W, SRC_H = 3840, 2160
TW, TH = 1728, 972
Q = 80

raw = np.fromfile("/tmp/raw4k.nv16", np.uint8)[: SRC_W * SRC_H * 2]
y = raw[: SRC_W * SRC_H].reshape(SRC_H, SRC_W)
c = raw[SRC_W * SRC_H:].reshape(SRC_H, SRC_W // 2, 2)

# --- 参考: 原尺寸直接转 BGR 再缩(和网页 _to_bgr 的 YUV 域缩放等价) ---
ys = cv2.resize(y, (TW, TH), interpolation=cv2.INTER_LINEAR)
cs = cv2.resize(c, (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
stage = np.concatenate([ys.reshape(-1), cs.reshape(-1)])
ref = M.yuv_to_bgr_c(stage, TW, TH, fmt="NV16", matrix="709",
                     rng="limited", swap_uv=False, nthreads=4)

# --- A: cv2 ---
ok, jb = cv2.imencode(".jpg", ref, [int(cv2.IMWRITE_JPEG_QUALITY), Q])
jpg_cv2 = jb.tobytes()
dec_cv2 = cv2.imdecode(np.frombuffer(jpg_cv2, np.uint8), cv2.IMREAD_COLOR)

# --- B: mpp (NV16 -> NV12) ---
nv12 = np.concatenate([ys.reshape(-1), np.ascontiguousarray(cs[::2]).reshape(-1)])
fb = nv12.tobytes()


def mpp_encode(nv12_bytes, colorimetry=None):
    caps = "video/x-raw,format=NV12,width=%d,height=%d" % (TW, TH)
    if colorimetry:
        caps += ",colorimetry=%s" % colorimetry
    cmd = ["gst-launch-1.0", "-q",
           "fdsrc", "fd=0", "blocksize=%d" % len(nv12_bytes), "!",
           "rawvideoparse", "format=nv12", "width=%d" % TW, "height=%d" % TH, "!"]
    # rawvideoparse 之后插一个 capsfilter 置 colorimetry
    if colorimetry:
        cmd += [caps, "!"]
    cmd += ["mppjpegenc", "!", "fdsink", "fd=1"]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, bufsize=0)
    out, _ = p.communicate(nv12_bytes)
    p.wait()
    s = out.find(b"\xff\xd8")
    e = out.find(b"\xff\xd9", s + 2)
    return out[s:e + 2] if s >= 0 and e > s else b""


def cmp(name, jpg):
    if not jpg:
        print("%-16s FAIL" % name)
        return
    dec = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
    if dec is None:
        print("%-16s decode FAIL" % name)
        return
    d = np.abs(dec.astype(np.int16) - ref.astype(np.int16))
    print("%-16s %6d B  mean|Δ| %5.2f  p99 %3d  BGR均值为 %s vs 参考 %s"
          % (name, len(jpg), d.mean(), int(np.percentile(d, 99)),
             np.round(dec.reshape(-1, 3).mean(axis=0), 1),
             np.round(ref.reshape(-1, 3).mean(axis=0), 1)))


print("参考 BGR 均值:", np.round(ref.reshape(-1, 3).mean(axis=0), 1))
cmp("cv2.imencode", jpg_cv2)
cmp("mpp (默认)", mpp_encode(fb))
cmp("mpp (bt709)", mpp_encode(fb, "bt709"))
