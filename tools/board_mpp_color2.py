"""判断 mpp 的偏色是否只是量程问题: 先把 YUV 展开到 full-range 再喂给它。"""
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

# --- 变体 A: Y 展开 limited->full, 色度按 224 展开 ---
lutY = np.clip((np.arange(256) - 16) * 255.0 / 219.0, 0, 255).astype(np.uint8)
lutf = np.clip((np.arange(256) - 128) * 255.0 / 224.0, -128, 127)
ys_f = lutY[ys]
cs_f = np.clip(np.round(cs.astype(np.float32) * (255.0 / 224.0) +
                        (128 - 128 * 255.0 / 224.0)), 0, 255).astype(np.uint8)

# --- 变体 B: 直接用我们的 C 库转 BGR, 再转 601 full 给 mpp ---
bgr = ref
yuv601 = cv2.cvtColor(bgr, cv2.COLOR_BGR2YUV)          # 601 full by default
y601 = np.ascontiguousarray(yuv601[:, :, 0])
uv601 = np.ascontiguousarray(np.stack([yuv601[0::2, 0::2, 1], yuv601[0::2, 0::2, 2]], axis=-1))


def mpp(nv12):
    fb = nv12.tobytes()
    cmd = ["gst-launch-1.0", "-q",
           "fdsrc", "fd=0", "blocksize=%d" % len(fb), "!",
           "rawvideoparse", "format=nv12", "width=%d" % TW, "height=%d" % TH, "!",
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
    print("%-22s %6dB mean|Δ| %5.2f p99 %3d  mean=%s"
          % (name, len(jpg), d.mean(), int(np.percentile(d, 99)),
             np.round(dec.reshape(-1, 3).mean(axis=0), 1)))


print("参考 mean:", np.round(ref.reshape(-1, 3).mean(axis=0), 1))
show("mpp 原始", mpp(np.concatenate([ys.reshape(-1),
                                     np.ascontiguousarray(cs[::2]).reshape(-1)])))
show("mpp 展开full-range", mpp(np.concatenate([ys_f.reshape(-1),
                                               np.ascontiguousarray(cs_f[::2]).reshape(-1)])))
show("mpp 601-full(先转BGR)", mpp(np.concatenate([y601.reshape(-1),
                                                  uv601.reshape(-1)])))
