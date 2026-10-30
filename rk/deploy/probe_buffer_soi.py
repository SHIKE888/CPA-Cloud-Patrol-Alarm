#!/opt/miniforge3/envs/mlk-ov/bin/python
# 在原始 buffer 里搜 FFD8FF, 判断 JPEG 到底在不在、在什么偏移。
import sys, os, time, math
import numpy as np
import cv2

DEV = "/dev/video22"
cap = cv2.VideoCapture(DEV, cv2.CAP_V4L2)
if not cap.isOpened():
    print("open FAIL"); sys.exit(1)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
try:
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
except Exception:
    pass
cap.set(cv2.CAP_PROP_BUFFERSIZE, 4)

deadline = time.time() + 25
got = 0
saved = 0
while time.time() < deadline and got < 8:
    ok, f = cap.read()
    if not ok or f is None:
        time.sleep(0.05); continue
    got += 1
    buf = f.reshape(-1).tobytes()
    n = len(buf)
    print("\n=== frame %d  size=%d ===" % (got, n))
    print("  head32 : %s" % buf[:32].hex())
    print("  tail32 : %s" % buf[-32:].hex())

    # 1) 搜 JPEG SOI
    hits, i = [], 0
    while True:
        i = buf.find(b"\xff\xd8\xff", i)
        if i < 0: break
        hits.append(i); i += 2
    print("  FFD8FF hits=%d  first=%s" % (len(hits), hits[:8]))

    # 2) 找 EOI
    if hits:
        off = hits[0]
        e = buf.find(b"\xff\xd9", off + 2)
        print("  first SOI@%d  EOI@%s  len=%s"
              % (off, e, (e - off + 2) if e > 0 else "NONE"))
        if e > 0 and saved < 3:
            open("/tmp/soi_%d.jpg" % saved, "wb").write(buf[off:e + 2])
            print("  saved /tmp/soi_%d.jpg" % saved)
            saved += 1

    # 3) 熵估计: 判断是真实码流还是随机/常量
    a = np.frombuffer(buf, dtype=np.uint8)
    uniq = len(np.unique(a))
    zero = float((a == 0).sum()) / n
    ff = float((a == 0xFF).sum()) / n
    print("  uniq_bytes=%d  zero_ratio=%.3f  ff_ratio=%.3f  mean=%.1f"
          % (uniq, zero, ff, a.mean()))

    # 4) 每 64KB 段的首字节 (看结构)
    seg = []
    for k in range(0, min(n, 512 * 1024), 65536):
        seg.append(buf[k:k + 2].hex())
    print("  64KB-step heads:", " ".join(seg[:8]))

    if got >= 4:
        break

cap.release()

# 分析提取出的 JPEG
import glob
for p in sorted(glob.glob("/tmp/soi_*.jpg")):
    fb = open(p, "rb").read()
    a = cv2.imdecode(np.frombuffer(fb, np.uint8), cv2.IMREAD_COLOR)
    if a is None:
        print("%s decode FAIL (len=%d)" % (p, len(fb))); continue
    h, w, _ = a.shape
    B = a[..., 0].astype(np.float32); G = a[..., 1].astype(np.float32); R = a[..., 2].astype(np.float32)
    print("\n=== %s  %dx%d  len=%d ===" % (p, w, h, len(fb)))
    print("  ALL: R=%6.1f G=%6.1f B=%6.1f std=%5.1f" % (R.mean(), G.mean(), B.mean(), a.std()))
    for name, x0, x1 in (("左半", 0, w // 2), ("右半", w // 2, w)):
        print("  %s: R=%6.1f G=%6.1f B=%6.1f std=%5.1f"
              % (name, R[:, x0:x1].mean(), G[:, x0:x1].mean(),
                 B[:, x0:x1].mean(), a[:, x0:x1].std()))
