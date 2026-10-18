"""mppjpegenc 硬件编码原型 (可用版): fdsrc -> rawvideoparse -> mppjpegenc -> fdsink

测: 吞吐 / 单帧往返延时 / 与 cv2.imencode 对比
"""
import queue
import subprocess
import threading
import time

import cv2
import numpy as np

SRC_W, SRC_H = 3840, 2160
TW, TH = 1728, 972
N = 120

raw = np.fromfile("/tmp/raw4k.nv16", np.uint8)[: SRC_W * SRC_H * 2]
y = raw[: SRC_W * SRC_H].reshape(SRC_H, SRC_W)
c = raw[SRC_W * SRC_H:].reshape(SRC_H, SRC_W // 2, 2)


def to_nv12(y, c, tw, th):
    ys = cv2.resize(y, (tw, th), interpolation=cv2.INTER_LINEAR)
    cs = cv2.resize(c, (tw // 2, th), interpolation=cv2.INTER_LINEAR)
    return np.concatenate([ys.reshape(-1), np.ascontiguousarray(cs[::2]).reshape(-1)])


t0 = time.time()
nv12 = to_nv12(y, c, TW, TH)
t_prep = (time.time() - t0) * 1e3
frame = nv12.tobytes()
print("prep(scale+NV16->NV12) %.1f ms, frame %d bytes" % (t_prep, len(frame)))

cmd = ["gst-launch-1.0", "-q",
       "fdsrc", "fd=0", "blocksize=%d" % len(frame), "!",
       "rawvideoparse", "format=nv12", "width=%d" % TW, "height=%d" % TH, "!",
       "mppjpegenc", "!",
       "fdsink", "fd=1"]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, bufsize=0)

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
for _ in range(3):
    p.stdin.write(frame)
p.stdin.flush()

lat = []
t0 = time.time()
for _ in range(N):
    t = time.time()
    p.stdin.write(frame)
    jpg = q.get(timeout=5.0)
    lat.append((time.time() - t) * 1e3)
el = time.time() - t0

# cv2 软件编码对照
bgr = cv2.cvtColor(nv12.reshape(TH * 3 // 2, TW), cv2.COLOR_YUV2BGR_NV12)
t1 = time.time()
for _ in range(30):
    cv2.imencode(".jpg", bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
t_sw = (time.time() - t1) / 30 * 1e3

p.stdin.close()
p.kill()

print("mpp : %.1f fps, 往返 avg %.1f ms max %.1f ms, jpeg %d KB"
      % (N / el, np.mean(lat), np.max(lat), len(jpg) // 1024))
print("cv2 : imencode %.1f ms  (BGR %dx%d)" % (t_sw, TW, TH))
