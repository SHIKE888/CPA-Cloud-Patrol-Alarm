#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""压测 2: 让 gst 自己划帧边界 (multipartmux + Content-Length)

fdsrc ! rawvideoparse(NV12/NV16) ! mppjpegenc ! multipartmux ! fdsink

用法: python3 mpptest2.py <文件> <W> <H> <帧数> <NV12|NV16>
"""
import os
import select
import subprocess
import sys
import time

import cv2
import numpy as np

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/small.nv12"
W = int(sys.argv[2]) if len(sys.argv) > 2 else 1728
H = int(sys.argv[3]) if len(sys.argv) > 3 else 972
N = int(sys.argv[4]) if len(sys.argv) > 4 else 60
FMT = (sys.argv[5] if len(sys.argv) > 5 else "NV12").upper()

FS = (W * H * 3 // 2) if FMT == "NV12" else (W * H * 2)
raw = np.fromfile(path, np.uint8)
frames = [raw[i * FS:(i + 1) * FS].tobytes() for i in range(len(raw) // FS)]
print("格式 %s 帧数 %d 单帧 %.2fMB" % (FMT, len(frames), FS / 1048576.0))
sys.stdout.flush()

BND = b"--framebnd"
cmd = ["gst-launch-1.0", "-q",
       "fdsrc", "fd=0", "blocksize=%d" % FS, "!",
       "rawvideoparse", "format=%s" % FMT.lower(),
       "width=%d" % W, "height=%d" % H, "!",
       "mppjpegenc", "!",
       "multipartmux", "boundary=framebnd", "!",
       "fdsink", "fd=1"]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, bufsize=0)
buf = bytearray()


def write_all(d):
    mv = memoryview(d)
    while mv:
        n = p.stdin.write(mv)
        if not n:
            raise IOError("short write")
        mv = mv[n:]


def read_available(wait):
    """按 multipart 头部里的 Content-Length 取帧。"""
    while True:
        r, _, _ = select.select([p.stdout.fileno()], [], [], wait)
        if not r:
            break
        d = os.read(p.stdout.fileno(), 1 << 16)
        if not d:
            break
        buf.extend(d)
        wait = 0.0
    got = []
    while True:
        i = buf.find(BND)
        if i < 0:
            break
        h = buf.find(b"\r\n\r\n", i)
        if h < 0:
            break
        head = bytes(buf[i:h]).decode("latin1", "replace")
        ln = -1
        for line in head.split("\r\n"):
            if line.lower().startswith("content-length:"):
                ln = int(line.split(":", 1)[1].strip())
                break
        if ln < 0:
            del buf[:h + 4]
            continue
        start = h + 4
        if len(buf) < start + ln:
            break
        got.append(bytes(buf[start:start + ln]))
        del buf[:start + ln + 2]
    return got


ok = bad = gray = 0
sizes = []
t0 = time.time()
for i in range(N):
    write_all(frames[i % len(frames)])
    g = read_available(0.5)
    if not g:
        print("  #%02d 超时(无帧) buf=%d" % (i, len(buf)))
        bad += 1
        continue
    jpg = g[-1]
    img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_GRAYSCALE)
    if img is None:
        print("  #%02d %7dB 解码失败" % (i, len(jpg)))
        bad += 1
        continue
    s = float(img.std())
    sizes.append(len(jpg))
    if s < 3.0 or len(jpg) < 2000:
        gray += 1
        print("  #%02d %7dB %dx%d std=%.1f  <<< 灰/坏" %
              (i, len(jpg), img.shape[1], img.shape[0], s))
    else:
        ok += 1

dt = time.time() - t0
print("---")
print("总 %d  正常 %d  灰/坏 %d  失败 %d   %.2fs (%.1f fps)" %
      (N, ok, gray, bad, dt, N / max(dt, 1e-6)))
if sizes:
    s = sorted(sizes)
    print("体积 min %d 中位 %d max %d" % (s[0], s[len(s) // 2], s[-1]))
sys.stdout.flush()
p.stdin.close()
try:
    p.kill()
except Exception:
    pass
