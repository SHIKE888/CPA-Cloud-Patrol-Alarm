#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立压测: fdsrc -> rawvideoparse(NV16) -> mppjpegenc -> fdsink
喂真实采集帧, 逐帧检查 JPEG 完整性, 找出截断/坏帧。
用法: python3 mpptest.py /tmp/seq.nv16 3840 2160 40
"""
import subprocess
import sys
import time

import cv2
import numpy as np

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/seq.nv16"
W = int(sys.argv[2]) if len(sys.argv) > 2 else 3840
H = int(sys.argv[3]) if len(sys.argv) > 3 else 2160
N = int(sys.argv[4]) if len(sys.argv) > 4 else 40
FMT = (sys.argv[5] if len(sys.argv) > 5 else "NV16").upper()

FS = (W * H * 3 // 2) if FMT == "NV12" else (W * H * 2)
raw = np.fromfile(path, np.uint8)
frames = [raw[i * FS:(i + 1) * FS].tobytes() for i in range(len(raw) // FS)]
print("格式 %s, 真实帧数 %d, 单帧 %.2f MB" % (FMT, len(frames), FS / 1048576.0))

cmd = ["gst-launch-1.0", "-q",
       "fdsrc", "fd=0", "blocksize=%d" % FS, "!",
       "rawvideoparse", "format=%s" % FMT.lower(),
       "width=%d" % W, "height=%d" % H, "!",
       "mppjpegenc", "!",
       "fdsink", "fd=1"]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, bufsize=0)

buf = bytearray()
sizes, ok, bad, gray = [], 0, 0, 0
t0 = time.time()


def write_all(d):
    mv = memoryview(d)
    while mv:
        n = p.stdin.write(mv)
        if not n:
            raise IOError("short write")
        mv = mv[n:]


def drain(wait=0.0):
    """读一次, 从 buf 里切出所有完整 JPEG 并统计。

    ★ 必须用 os.read 而不能用 p.stdout.read(n):
      buffered reader 的 read(n) 会一直等到凑满 n 字节, 配合 select 会死锁。
    """
    global ok, bad, gray
    got = []
    import os
    import select
    while True:
        r, _, _ = select.select([p.stdout.fileno()], [], [], wait)
        if not r:
            break
        d = os.read(p.stdout.fileno(), 1 << 16)
        if not d:
            break
        buf.extend(d)
        wait = 0.0
    while True:
        s = buf.find(b"\xff\xd8")
        if s < 0:
            break
        e = buf.find(b"\xff\xd9", s + 2)
        if e < 0:
            break
        jpg = bytes(buf[s:e + 2])
        del buf[:e + 2]
        got.append(jpg)
    return got


for i in range(N):
    write_all(frames[i % len(frames)])
    got = drain(0.8)
    if not got:
        print("  #%02d 超时: 没拿到 JPEG (buf=%d)" % (i, len(buf)))
        bad += 1
        continue
    jpg = got[-1]
    img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_GRAYSCALE)
    if img is None:
        print("  #%02d %7d B  解码失败" % (i, len(jpg)))
        bad += 1
        continue
    std = float(img.std())
    sizes.append(len(jpg))
    flag = ""
    if std < 3.0 or len(jpg) < 2000:
        gray += 1
        flag = "  <<< 可疑(灰)"
    elif got[-1][-2:] != b"\xff\xd9":
        bad += 1
        flag = "  <<< 无 EOI"
    else:
        ok += 1
    print("  #%02d %7d B  %dx%d  std=%.1f%s" % (i, len(jpg), img.shape[1], img.shape[0], std, flag))

dt = time.time() - t0
p.stdin.close()
try:
    p.kill()
except Exception:
    pass
print("---")
print("总计 %d 帧, 正常 %d, 可疑 %d, 失败 %d, 耗时 %.2fs (%.1f fps)" %
      (N, ok, gray, bad, dt, N / dt))
if sizes:
    s = sorted(sizes)
    print("体积: min %d  p5 %d  中位 %d  max %d" %
          (s[0], s[len(s) // 20], s[len(s) // 2], s[-1]))
