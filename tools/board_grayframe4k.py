"""4K 下扫 /stream: 先只看 JPEG 大小(不解码, 快), 异常小的再解码确认是否灰帧。"""
import time
import urllib.request

import cv2
import numpy as np

URL = "http://127.0.0.1:9012/stream"
DUR = 20.0

t0 = time.time()
resp = urllib.request.urlopen(URL, timeout=10)
buf = bytearray()
sizes = []
jpgs = []
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

print("frames: %d in %.1fs -> %.1f fps" % (len(sizes), DUR, len(sizes) / DUR))
if sizes:
    a = np.array(sizes)
    print("jpeg size: min %d p5 %d median %d max %d"
          % (a.min(), int(np.percentile(a, 5)), int(np.median(a)), a.max()))
    med = np.median(a)
    odd = [i for i, v in enumerate(sizes) if v < med * 0.5 or v > med * 2]
    print("outliers: %d %s" % (len(odd), odd[:10]))
    for i in odd[:6]:
        im = cv2.imdecode(np.frombuffer(jpgs[i], np.uint8), cv2.IMREAD_COLOR)
        if im is None:
            print("  #%d size=%d  DECODE FAIL" % (i, sizes[i]))
        else:
            m = im.reshape(-1, 3).mean(axis=0)
            print("  #%d size=%d  shape=%s  mean=%s  std=%.1f"
                  % (i, sizes[i], im.shape, np.round(m, 1), im.std()))
