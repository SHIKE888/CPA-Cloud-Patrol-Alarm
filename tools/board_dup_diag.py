"""判定重复帧出在服务端编码器还是 socket 传输。

同时记录: 收到的帧号增量(服务端 hub frame_id) vs 收到的总帧数 vs 唯一帧数。
"""
import hashlib
import json
import time
import urllib.request

URL_STREAM = "http://127.0.0.1:9012/stream"
URL_SYS = "http://127.0.0.1:9012/api/sys"
DUR = 20.0


def fid():
    with urllib.request.urlopen(URL_SYS, timeout=5) as r:
        return json.load(r)["frame_id"]


f0 = fid()
resp = urllib.request.urlopen(URL_STREAM, timeout=10)
buf = bytearray()
h = []
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
        jpg = bytes(buf[s:e + 2])
        del buf[:e + 2]
        h.append(hashlib.md5(jpg).hexdigest()[:10])
        sizes.append(len(jpg))
f1 = fid()

print("server frame_id 增量 : %d" % (f1 - f0))
print("收到 JPEG 总数       : %d" % len(h))
print("唯一 JPEG 数         : %d" % len(set(h)))
dup_run = 0
for i in range(1, len(h)):
    if h[i] == h[i - 1]:
        dup_run += 1
print("相邻重复次数         : %d" % dup_run)
print("前 30 个 md5:", " ".join(h[:30]))
print("size 前 12:", sizes[:12])
