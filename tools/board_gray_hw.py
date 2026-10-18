"""硬件编码开启时扫描 /stream，统计灰帧 / 截断帧 / 重复帧。"""
import hashlib
import time
import urllib.request

import cv2
import numpy as np

URL = "http://127.0.0.1:9012/stream"
DUR = 15.0

resp = urllib.request.urlopen(URL, timeout=10)
buf = bytearray()
jpgs = []
sizes = []
t0 = time.time()
while time.time() - t0 < DUR:
    d = resp.read(262144)
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
        jpgs.append(bytes(buf[s:e + 2]))
        sizes.append(e + 2 - s)
        del buf[:e + 2]

print("frames %d (%.1f fps)" % (len(sizes), len(sizes) / DUR))
if not sizes:
    raise SystemExit
a = np.array(sizes)
print("size: min %d p5 %d median %d max %d" %
      (a.min(), int(np.percentile(a, 5)), int(np.median(a)), a.max()))

md5 = [hashlib.md5(j).hexdigest() for j in jpgs]
print("unique: %d / %d" % (len(set(md5)), len(md5)))

bad = []
for i, j in enumerate(jpgs):
    im = cv2.imdecode(np.frombuffer(j, np.uint8), cv2.IMREAD_COLOR)
    if im is None:
        bad.append((i, sizes[i], "decode fail"))
        continue
    m = float(im.reshape(-1, 3).mean())
    sd = float(im.std())
    if sd < 20:
        bad.append((i, sizes[i], "flat mean=%.0f std=%.1f" % (m, sd)))
    elif abs(m - 128) < 12 and sd < 45:
        bad.append((i, sizes[i], "grayish mean=%.0f std=%.1f" % (m, sd)))
print("可疑帧: %d %s" % (len(bad), bad[:10]))
