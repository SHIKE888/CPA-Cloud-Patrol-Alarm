"""从 /stream 抓 N 秒, 解出每帧的均值/方差, 找出“灰帧”。

灰帧特征: BGR 三通道都接近 128 且方差很小(纯灰)。
"""
import time
import urllib.request

import cv2
import numpy as np

URL = "http://127.0.0.1:9012/stream"
DUR = 15.0

t0 = time.time()
resp = urllib.request.urlopen(URL, timeout=10)
buf = bytearray()
frames = []
gray_like = []
while time.time() - t0 < DUR:
    d = resp.read(65536)
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
        jpg = bytes(buf[s:e + 2])
        del buf[:e + 2]
        im = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
        if im is None:
            continue
        m = im.reshape(-1, 3).mean(axis=0)
        sd = float(im.std())
        frames.append((len(jpg), m, sd))
        # 纯灰: 三通道差 < 6 且 100<均值<160 且 方差小
        if abs(m[0] - m[1]) < 6 and abs(m[1] - m[2]) < 6 and 95 < m.mean() < 165 and sd < 25:
            gray_like.append((len(frames) - 1, round(float(m.mean()), 1), round(sd, 1)))

print("frames: %d in %.1fs -> %.1f fps" % (len(frames), DUR, len(frames) / DUR))
if frames:
    sizes = [f[0] for f in frames]
    means = [float(f[1].mean()) for f in frames]
    print("jpeg size: min %d max %d avg %d" % (min(sizes), max(sizes), sum(sizes) / len(sizes)))
    print("frame mean: min %.1f max %.1f avg %.1f" % (min(means), max(means), sum(means) / len(means)))
print("gray-like frames: %d %s" % (len(gray_like), gray_like[:12]))
