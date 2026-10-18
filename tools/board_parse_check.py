"""用 gray_hw.py 同样的增量解析逻辑, 处理已保存的干净原始流, 看是否也会切出短帧。"""
import cv2
import numpy as np

d = open("/tmp/stream_raw.bin", "rb").read()

buf = bytearray()
segs = []
CHUNK = 262144
i = 0
while i < len(d):
    buf.extend(d[i:i + CHUNK])
    i += CHUNK
    while True:
        s = buf.find(b"\xff\xd8")
        if s < 0:
            break
        e = buf.find(b"\xff\xd9", s + 2)
        if e < 0:
            break
        segs.append(bytes(buf[s:e + 2]))
        del buf[:e + 2]

lens = [len(x) for x in segs]
a = np.array(lens)
print("增量解析得到 %d 段  min %d p5 %d median %d max %d"
      % (len(lens), a.min(), int(np.percentile(a, 5)), int(np.median(a)), a.max()))
bad = 0
for k, seg in enumerate(segs):
    im = cv2.imdecode(np.frombuffer(seg, np.uint8), cv2.IMREAD_COLOR)
    if im is None:
        bad += 1
        if bad <= 5:
            print("  解码失败 #%d len=%d 头=%s 尾=%s" % (k, len(seg), seg[:2].hex(), seg[-2:].hex()))
print("解码失败: %d / %d" % (bad, len(segs)))
