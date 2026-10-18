#!/bin/sh
# 验证硬件编码开关 + 灰帧防护
PY=/opt/miniforge3/envs/mlk-ov/bin/python
API=http://127.0.0.1:9012
echo "== 初始 =="
curl -s -m 5 $API/api/jpeg; echo
echo "== 打开硬件编码 =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -d '{"hw":true}' $API/api/jpeg; echo
sleep 2
echo "== 抓 20 秒流, 统计灰帧 =="
$PY - <<'PYEOF'
import urllib.request
import numpy as np
import cv2

r = urllib.request.urlopen("http://127.0.0.1:9012/stream", timeout=10)
buf = bytearray()
tot = bad = 0
import time
t0 = time.time()
while time.time() - t0 < 20:
    d = r.read(65536)
    if not d:
        break
    buf.extend(d)
    while True:
        h = buf.find(b"\r\n\r\n")
        if h < 0:
            break
        head = bytes(buf[:h]).decode("latin1", "replace")
        ln = -1
        for line in head.split("\r\n"):
            if line.lower().startswith("content-length:"):
                ln = int(line.split(":", 1)[1])
        if ln < 0:
            del buf[:h + 4]
            continue
        if len(buf) < h + 4 + ln:
            break
        jpg = bytes(buf[h + 4:h + 4 + ln])
        del buf[:h + 4 + ln + 2]
        img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_GRAYSCALE)
        tot += 1
        if img is None or float(img.std()) < 3.0:
            bad += 1
print("流内帧数 %d, 灰/坏 %d" % (tot, bad))
PYEOF
echo "== 结束状态 =="
curl -s -m 5 $API/api/jpeg; echo
echo "== 关回软件 =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -d '{"hw":false}' $API/api/jpeg; echo
