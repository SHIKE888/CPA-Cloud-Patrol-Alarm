#!/bin/sh
# 从推流里抓一帧实际显示的图像并做分区统计。
# 走 cv2.imdecode 路径 = 用户实际看到的画面, 不碰 v4l2 设备。

PY=/opt/miniforge3/envs/mlk-ov/bin/python

echo "== 可用端点 =="
curl -s -m 5 http://127.0.0.1:9012/api/sys | $PY -c "import sys,json;d=json.load(sys.stdin);print('fps',d.get('fps'),'frame_id',d.get('frame_id'),'capture',d.get('capture'))" 2>&1

echo
echo "== 抓推流首帧 =="
for EP in /stream /mjpeg /video /raw; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -m 3 --max-time 3 "http://127.0.0.1:9012$EP" 2>/dev/null)
    echo "  $EP -> $code"
done

# 主流端点一般为 /stream, 抓 3 秒内的数据
curl -s -m 6 "http://127.0.0.1:9012/stream" -o /tmp/stream.mjpeg 2>/dev/null
ls -la /tmp/stream.mjpeg 2>/dev/null

echo
echo "== 解析 MJPEG 边界并统计 =="
$PY - <<'PYEOF'
import os
p = "/tmp/stream.mjpeg"
if not os.path.exists(p) or os.path.getsize(p) < 100:
    print("没抓到流数据, size=", os.path.getsize(p) if os.path.exists(p) else "N/A")
    raise SystemExit(0)

raw = open(p, "rb").read()
print("stream size:", len(raw))
print("head:", raw[:32].hex())

# MJPEG multipart: 找每个 FFD8..FFD9
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

print("frames found:", len(frames), "sizes:", [len(f) for f in frames[:5]])
if not frames:
    raise SystemExit(0)

try:
    from PIL import Image
    import numpy as np, io
except Exception as ex:
    print("no PIL/numpy:", ex); raise SystemExit(0)

for k, fb in enumerate(frames[:3]):
    try:
        im = Image.open(io.BytesIO(fb)); im.load()
        a = np.asarray(im.convert("RGB")).astype(np.float32)
        h, w, _ = a.shape
        print("\n--- frame %d: %dx%d mode=%s ---" % (k, w, h, im.mode))
        # 8 宫格
        for ri in range(2):
            for ci in range(4):
                y0, y1 = ri * h // 2, (ri + 1) * h // 2
                x0, x1 = ci * w // 4, (ci + 1) * w // 4
                b = a[y0:y1, x0:x1]
                print("  r%d c%d: R=%6.1f G=%6.1f B=%6.1f std=%5.1f"
                      % (ri, ci, b[..., 0].mean(), b[..., 1].mean(),
                         b[..., 2].mean(), b.std()))
        # 整体
        print("  ALL   : R=%6.1f G=%6.1f B=%6.1f"
              % (a[..., 0].mean(), a[..., 1].mean(), a[..., 2].mean()))
        # 保存便于人工查看
        open("/tmp/stream_frame_%d.jpg" % k, "wb").write(fb)
    except Exception as ex:
        print("frame %d ERROR %s" % (k, ex))
PYEOF
