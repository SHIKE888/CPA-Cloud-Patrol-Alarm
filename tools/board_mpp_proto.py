"""mppjpegenc 硬件编码原型: fdsrc -> NV12 -> mppjpegenc -> stdout, 自己抠 JPEG。

测三件事: 吞吐、单帧延时、CPU 占用。
"""
import os
import subprocess
import sys
import time

import numpy as np

W, H = 3840, 2160
TW, TH = 1728, 972
N = 120

raw = np.fromfile("/tmp/raw4k.nv16", np.uint8)[: W * H * 2]
y = raw[: W * H].reshape(H, W)
c = raw[W * H:].reshape(H, W // 2, 2)

import cv2  # noqa: E402

ys = cv2.resize(y, (TW, TH), interpolation=cv2.INTER_LINEAR)
cs = cv2.resize(c, (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
# NV16 -> NV12: 色度只保留偶数行
cs12 = np.ascontiguousarray(cs[::2])
frame = np.concatenate([ys.reshape(-1), cs12.reshape(-1)]).tobytes()
print("NV12 frame bytes:", len(frame), "expect", TW * TH * 3 // 2)

FB = len(frame)
cmd = [
    "gst-launch-1.0", "-q",
    "fdsrc", "fd=0", "blocksize=%d" % FB, "!",
    "video/x-raw,format=NV12,width=%d,height=%d,framerate=25/1" % (TW, TH), "!",
    "mppjpegenc", "!",
    "fdsink", "fd=1",
]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, bufsize=0)

# 读取线程: 按 SOI/EOI 抠 JPEG
import threading
import queue

q = queue.Queue()
buf = bytearray()


def reader():
    while True:
        d = p.stdout.read(65536)
        if not d:
            break
        buf.extend(d)
        while True:
            s = buf.find(b"\xff\xd8")
            if s < 0:
                break
            e = buf.find(b"\xff\xd9", s + 2)
            if e < 0:
                break
            q.put(bytes(buf[s:e + 2]))
            del buf[:e + 2]


threading.Thread(target=reader, daemon=True).start()

# 预热
for _ in range(3):
    p.stdin.write(frame)
t0 = time.time()
sent = []
for i in range(N):
    t = time.time()
    p.stdin.write(frame)
    p.stdin.flush()
    jpg = q.get(timeout=5.0)
    sent.append((time.time() - t) * 1e3)
el = time.time() - t0
p.stdin.close()
p.kill()

print("frames %d  wall %.2fs  => %.1f fps" % (N, el, N / el))
print("per-frame latency: avg %.1f ms  max %.1f ms  jpeg %d KB"
      % (np.mean(sent), np.max(sent), len(jpg) // 1024))
