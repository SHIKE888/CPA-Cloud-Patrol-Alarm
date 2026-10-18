"""逐段解码 /tmp/stream_raw.bin 里每一帧, 统计失败/异常段。"""
import cv2
import numpy as np

d = open("/tmp/stream_raw.bin", "rb").read()
soi = [i for i in range(len(d) - 1) if d[i] == 0xFF and d[i + 1] == 0xD8]
segs = []
for k in range(len(soi) - 1):
    s, s2 = soi[k], soi[k + 1]
    e = d.find(b"\xff\xd9", s + 2)
    segs.append((s, s2 - s, e - s + 2))

lens = [x[1] for x in segs]
a = np.array(lens)
print("段数 %d  size: min %d p5 %d median %d max %d"
      % (len(lens), a.min(), int(np.percentile(a, 5)), int(np.median(a)), a.max()))

bad = 0
for k, (s, seglen, jlen) in enumerate(segs):
    seg = d[s:s + jlen]
    im = cv2.imdecode(np.frombuffer(seg, np.uint8), cv2.IMREAD_COLOR)
    if im is None or jlen < seglen - 200:
        bad += 1
        if bad <= 8:
            print("  异常段 %d: 段长 %d, JPEG 长 %d, 解码=%s"
                  % (k, seglen, jlen, "OK" if im is not None else "FAIL"))
print("异常段: %d / %d" % (bad, len(segs)))
