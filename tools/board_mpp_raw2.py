"""喂 20 帧【各不相同】的画面, 检查 mppjpegenc 输出每帧是否完整。"""
import subprocess
import sys

import cv2
import numpy as np

TW, TH = 1728, 972
FB = TW * TH * 3 // 2
N = 20

d = np.fromfile("/tmp/raw4k.nv16", np.uint8)
y = d[: 3840 * 2160].reshape(2160, 3840)
c = d[3840 * 2160: 3840 * 2160 * 2].reshape(2160, 1920, 2)

frames = []
for k in range(N):
    yy = np.roll(y, k * 7, axis=1)
    ys = cv2.resize(yy, (TW, TH), interpolation=cv2.INTER_LINEAR)
    cs = cv2.resize(c, (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
    frames.append(np.concatenate([ys.reshape(-1),
                                  np.ascontiguousarray(cs[::2]).reshape(-1)]).tobytes())

cmd = ["gst-launch-1.0", "-q",
       "fdsrc", "fd=0", "blocksize=%d" % FB, "!",
       "rawvideoparse", "format=nv12", "width=%d" % TW, "height=%d" % TH,
       "framerate=25/1", "!",
       "mppjpegenc", "!",
       "fdsink", "fd=1"]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
out, _ = p.communicate(b"".join(frames))
p.wait()

soi = [i for i in range(len(out) - 1) if out[i] == 0xFF and out[i + 1] == 0xD8]
eoi = [i for i in range(len(out) - 1) if out[i] == 0xFF and out[i + 1] == 0xD9]
print("frames sent %d, bytes %d" % (N, len(out)))
print("SOI %d / EOI %d" % (len(soi), len(eoi)))
ok = 0
for k in range(min(N, len(soi))):
    s = soi[k]
    e = out.find(b"\xff\xd9", s + 2)
    seg = out[s:e + 2]
    im = cv2.imdecode(np.frombuffer(seg, np.uint8), cv2.IMREAD_COLOR)
    good = im is not None
    ok += good
    if k < 6 or not good:
        print("  帧%02d len=%d 解码=%s" % (k, len(seg), "OK" if good else "FAIL"))
print("可解码 %d/%d" % (ok, min(N, len(soi))))
print("各帧长度:", sorted(set(e - s + 2 for s, e in
                            [(soi[k], out.find(b"\xff\xd9", soi[k] + 2))
                             for k in range(min(N, len(soi)))]))[:10])
