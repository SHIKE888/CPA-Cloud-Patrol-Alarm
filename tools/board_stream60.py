"""60s 长跑: 逐帧均值 + 重复帧检测 (只在异常时才解码)。"""
import time
import urllib.request

import cv2
import numpy as np

URL = "http://127.0.0.1:9012/stream"
DUR = 60.0

resp = urllib.request.urlopen(URL, timeout=10)
buf = bytearray()
sizes, means, hashes = [], [], []
jpgs = {}
t0 = time.time()
last_t = t0
gaps = []
while time.time() - t0 < DUR:
    d = resp.read(262144)
    if not d:
        break
    now = time.time()
    gaps.append(now - last_t)
    last_t = now
    buf.extend(d)
    while True:
        s = buf.find(b"\xff\xd8")
        if s < 0:
            break
        e = buf.find(b"\xff\xd9", s + 2)
        if e < 0:
            break
        jpg = bytes(buf[s:e + 2])
        del buf[:e + 2]
        sizes.append(len(jpg))
        hashes.append(hash(jpg))
        jpgs[len(sizes) - 1] = jpg

print("frames %d, %.1f fps" % (len(sizes), len(sizes) / DUR))
a = np.array(sizes)
print("size: min %d p1 %d median %d max %d" %
      (a.min(), int(np.percentile(a, 1)), int(np.median(a)), a.max()))

uniq = len(set(hashes))
print("unique jpeg: %d (%d 重复)" % (uniq, len(hashes) - uniq))

# 连续重复
runs, run = 0, 0
for i in range(1, len(hashes)):
    if hashes[i] == hashes[i - 1]:
        run += 1
    else:
        if run:
            runs += 1
        run = 0
print("连续重复段: %d 处" % runs)

# 大间隔(>0.5s) = 卡顿
big = [round(g * 1000) for g in gaps if g > 0.5]
print(">500ms 的读间隔: %d 次 %s" % (len(big), big[:8]))

# 解码所有帧的均值(慢一点, 但只做统计)
for i in range(0, len(sizes), max(1, len(sizes) // 120)):
    im = cv2.imdecode(np.frombuffer(jpgs[i], np.uint8), cv2.IMREAD_COLOR)
    if im is not None:
        means.append(float(im.reshape(-1, 3).mean()))
if means:
    print("抽样帧均值: min %.1f max %.1f avg %.1f (跨度 %.1f)"
          % (min(means), max(means), sum(means) / len(means), max(means) - min(means)))
