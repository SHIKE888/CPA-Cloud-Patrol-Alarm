# 分析 JPEG 码流里的 RST 标记 (FF D0..D7) 位置 = 段边界
import sys

def markers(data):
    out = []
    i = 0
    n = len(data)
    while i < n - 1:
        if data[i] == 0xFF and data[i+1] in range(0xD0, 0xD8):
            out.append((i, data[i+1]))
            i += 2
        else:
            i += 1
    return out

def report(name, data):
    print('=' * 70)
    print('%s: len=%d' % (name, len(data)))
    ms = markers(data)
    # SOI / EOI
    print('  SOI=FF D8 @', data.find(b'\xff\xd8'))
    print('  EOI=FF D9 @', data.find(b'\xff\xd9'))
    prev = 0
    seg = 0
    for off, m in ms:
        print('  RST %s seg=%2d  seg_bytes=%4d  (offset %d..%d)' %
              ('%02X' % m, seg, off - prev, prev, off))
        seg += 1
        prev = off
    if ms:
        print('  尾部(last seg) bytes=%d' % (len(data) - prev))

base = open('segb.jpg', 'rb').read()
s1   = open('s1.jpg', 'rb').read()
v54  = open('v54.jpg', 'rb').read()

report('base(6007)', base)
report('STEP1(6446)', s1)
report('V54(7166)', v54)

# 4661 落在 base 的哪个段?
print('=' * 70)
print('4661 在 base 中的位置:')
ms = markers(base)
prev = 0
for seg_i, (off, m) in enumerate(ms):
    if prev <= 4661 < off:
        print('  seg=%d (RST %02X), 段内偏移 %d' % (seg_i, m, 4661 - prev))
    prev = off
