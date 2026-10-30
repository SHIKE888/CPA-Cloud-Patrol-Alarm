#!/opt/miniforge3/envs/mlk-ov/bin/python
# 直接读 /dev/video22 的原始 buffer, 提取 FPGA 输出的原始 JPEG (3840x1080, 未缩放)
# 需先停 mipi-webstream 释放设备。
import sys, os, time
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

print("neg width=%d height=%d" % (cap.get(cv2.CAP_PROP_FRAME_WIDTH),
                                  cap.get(cv2.CAP_PROP_FRAME_HEIGHT)))

deadline = time.time() + 25
got = 0
while time.time() < deadline and got < 6:
    ok, f = cap.read()
    if not ok or f is None:
        time.sleep(0.05)
        continue
    got += 1
    buf = f.reshape(-1)
    head = buf[:12].tobytes().hex()
    isj = (buf.size > 1 and buf[0] == 0xFF and buf[1] == 0xD8)
    print("frame %d shape=%s head=%s isJPEG=%s" % (got, f.shape, head, isj))
    if not isj:
        continue
    b = buf.tobytes()
    e = b.find(b"\xff\xd9", 2)
    if e < 1024:
        print("   no EOI, first 200KB saved")
        open("/tmp/orig_raw.bin", "wb").write(b[:400000])
        continue
    jpg = b[:e + 2]
    print("   JPEG len=%d" % len(jpg))
    open("/tmp/orig_%d.jpg" % got, "wb").write(jpg)
    if got >= 3:
        break

cap.release()

# 分析拿到的原始 JPEG
import glob
for p in sorted(glob.glob("/tmp/orig_*.jpg")):
    fb = open(p, "rb").read()
    a = cv2.imdecode(np.frombuffer(fb, np.uint8), cv2.IMREAD_COLOR)
    if a is None:
        print("%s decode FAIL" % p); continue
    h, w, _ = a.shape
    B, G, R = a[..., 0].astype(np.float32), a[..., 1].astype(np.float32), a[..., 2].astype(np.float32)
    print("\n=== %s  %dx%d  len=%d ===" % (p, w, h, len(fb)))
    print("  ALL : R=%6.1f G=%6.1f B=%6.1f std=%5.1f"
          % (R.mean(), G.mean(), B.mean(), a.std()))
    # 左右两半 (3840 宽时 x<1920 = 左路, x>=1920 = 右路)
    for name, x0, x1 in (("左半", 0, w // 2), ("右半", w // 2, w)):
        sub_b, sub_g, sub_r = B[:, x0:x1], G[:, x0:x1], R[:, x0:x1]
        print("  %s: R=%6.1f G=%6.1f B=%6.1f std=%5.1f"
              % (name, sub_r.mean(), sub_g.mean(), sub_b.mean(),
                 a[:, x0:x1].std()))
    # 细分 8 格
    for ri in range(2):
        for ci in range(4):
            y0, y1 = ri * h // 2, (ri + 1) * h // 2
            x0, x1 = ci * w // 4, (ci + 1) * w // 4
            print("    r%dc%d: R=%6.1f G=%6.1f B=%6.1f std=%5.1f"
                  % (ri, ci, R[y0:y1, x0:x1].mean(), G[y0:y1, x0:x1].mean(),
                     B[y0:y1, x0:x1].mean(), a[y0:y1, x0:x1].std()))
