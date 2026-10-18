"""抓 /stream 原始字节(硬件编码开), 统计 SOI/EOI 分布, 判断是"流里有额外 EOI"还是"真截断"。"""
import subprocess
import time

# 5 秒原始字节
subprocess.run("timeout 5 curl -s -o /tmp/stream_raw.bin http://127.0.0.1:9012/stream",
               shell=True)
d = open("/tmp/stream_raw.bin", "rb").read()
print("bytes:", len(d))

soi = [i for i in range(len(d) - 1) if d[i] == 0xFF and d[i + 1] == 0xD8]
eoi = [i for i in range(len(d) - 1) if d[i] == 0xFF and d[i + 1] == 0xD9]
print("SOI:", len(soi), " EOI:", len(eoi))
print("前 6 SOI:", soi[:6])
print("前 6 EOI:", eoi[:6])

# 前面是 multipart 头, 找第一个 SOI 之后的间隔
if len(soi) > 1:
    gaps = [soi[i + 1] - soi[i] for i in range(min(12, len(soi) - 1))]
    print("SOI 间隔:", gaps)
if len(eoi) > 1:
    gaps = [eoi[i + 1] - eoi[i] for i in range(min(12, len(eoi) - 1))]
    print("EOI 间隔:", gaps)

# 每个 SOI 到下一个 SOI 之间的字节数, 以及其中是否有多个 EOI
for k in range(min(8, len(soi) - 1)):
    s, s2 = soi[k], soi[k + 1]
    seg = d[s:s2]
    n_eoi = seg.count(b"\xff\xd9")
    print("  段%d: 长度 %d, 内含 EOI 数 %d, 结尾4字节 %s"
          % (k, len(seg), n_eoi, seg[-4:].hex()))
