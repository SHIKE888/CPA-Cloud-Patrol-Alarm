"""抓 mppjpegenc 的原始输出字节流, 看每帧 JPEG 的边界是否规整。"""
import subprocess
import sys

import cv2
import numpy as np

sys.path.insert(0, "/root/rk/web")

TW, TH = 1728, 972
FB = TW * TH * 3 // 2
N = 20

# 用一张真实画面合成 NV12
y = np.fromfile("/tmp/raw4k.nv16", np.uint8)
if y.size < 3840 * 2160 * 2:
    raise SystemExit("need /tmp/raw4k.nv16")
y = y[: 3840 * 2160].reshape(2160, 3840)
c = np.fromfile("/tmp/raw4k.nv16", np.uint8)[3840 * 2160:3840 * 2160 * 2].reshape(2160, 1920, 2)
ys = cv2.resize(y, (TW, TH), interpolation=cv2.INTER_LINEAR)
cs = cv2.resize(c, (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
frame = np.concatenate([ys.reshape(-1), np.ascontiguousarray(cs[::2]).reshape(-1)]).tobytes()
assert len(frame) == FB, (len(frame), FB)

cmd = ["gst-launch-1.0", "-q",
       "fdsrc", "fd=0", "blocksize=%d" % FB, "!",
       "rawvideoparse", "format=nv12", "width=%d" % TW, "height=%d" % TH, "!",
       "mppjpegenc", "!",
       "fdsink", "fd=1"]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
out, _ = p.communicate(frame * N)
p.wait()

print("sent %d frames, got %d bytes (avg %.1f B/frame)" % (N, len(out), len(out) / N))

# 统计 SOI / EOI
soi = [i for i in range(len(out) - 1) if out[i] == 0xFF and out[i + 1] == 0xD8]
eoi = [i for i in range(len(out) - 1) if out[i] == 0xFF and out[i + 1] == 0xD9]
print("SOI 个数: %d   EOI 个数: %d" % (len(soi), len(eoi)))
print("前 8 个 SOI 位置:", soi[:8])
print("前 8 个 EOI 位置:", eoi[:8])
if len(soi) > 1:
    print("相邻 SOI 间隔:", [soi[i + 1] - soi[i] for i in range(min(8, len(soi) - 1))])
if len(eoi) > 1:
    print("相邻 EOI 间隔:", [eoi[i + 1] - eoi[i] for i in range(min(8, len(eoi) - 1))])

# 按 SOI 切, 找每个 JPEG 里第一个 EOI 的位置(相对)
for k in range(min(6, len(soi))):
    s = soi[k]
    e = out.find(b"\xff\xd9", s + 2)
    print("  帧%d: SOI@%d, 第一个 EOI 相对 %d, 该 JPEG 长 %d" % (k, s, e - s, e - s + 2))
    seg = out[s:e + 2]
    im = cv2.imdecode(np.frombuffer(seg, np.uint8), cv2.IMREAD_COLOR)
    print("       解码: %s" % ("OK " + str(im.shape) if im is not None else "FAIL"))

open("/tmp/mpp_raw.bin", "wb").write(out)
print("raw saved /tmp/mpp_raw.bin")
