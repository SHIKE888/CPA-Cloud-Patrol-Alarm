#!/bin/sh
# 用 cv2 解析推流帧, 统计分区颜色, 并落盘供回传查看。
PY=/opt/miniforge3/envs/mlk-ov/bin/python

curl -s -m 8 "http://127.0.0.1:9012/stream" -o /tmp/stream.mjpeg 2>/dev/null
ls -la /tmp/stream.mjpeg

$PY - <<'PYEOF'
import os, numpy as np, cv2
p = "/tmp/stream.mjpeg"
if not os.path.exists(p) or os.path.getsize(p) < 100:
    print("no stream"); raise SystemExit(0)

raw = open(p, "rb").read()
print("stream size:", len(raw))

frames, i = [], 0
while True:
    s = raw.find(b"\xff\xd8\xff", i)
    if s < 0:
        break
    e = raw.find(b"\xff\xd9", s + 2)
    if e < 0:
        break
    frames.append(raw[s:e + 2])
    i = e + 2
print("frames:", len(frames), "sizes:", [len(f) for f in frames[:6]])
if not frames:
    raise SystemExit(0)

for k, fb in enumerate(frames[:4]):
    a = cv2.imdecode(np.frombuffer(fb, np.uint8), cv2.IMREAD_COLOR)
    if a is None:
        print("frame %d decode FAIL" % k); continue
    h, w, _ = a.shape
    bgr = a.astype(np.float32)
    B, G, R = bgr[..., 0], bgr[..., 1], bgr[..., 2]
    print("\n=== frame %d: %dx%d  len=%d ===" % (k, w, h, len(fb)))
    print("  ALL: R=%6.1f G=%6.1f B=%6.1f  std=%5.1f"
          % (R.mean(), G.mean(), B.mean(), a.std()))
    for ri in range(2):
        row = []
        for ci in range(4):
            y0, y1 = ri * h // 2, (ri + 1) * h // 2
            x0, x1 = ci * w // 4, (ci + 1) * w // 4
            row.append("R%5.0f G%5.0f B%5.0f"
                       % (R[y0:y1, x0:x1].mean(),
                          G[y0:y1, x0:x1].mean(),
                          B[y0:y1, x0:x1].mean()))
        print("  row%d: %s" % (ri, " | ".join(row)))
    # 存一份原始 + 缩小预览
    open("/tmp/sf_%d.jpg" % k, "wb").write(fb)
    cv2.imwrite("/tmp/sf_%d_small.png" % k, cv2.resize(a, (960, h * 960 // w)))
    print("  saved /tmp/sf_%d.jpg" % k)
PYEOF
