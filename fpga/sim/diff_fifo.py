import difflib

def load(p):
    return open(p, 'rb').read()

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

def seg_report(name, data):
    print('=' * 70)
    print('%s: len=%d' % (name, len(data)))
    ms = markers(data)
    print('  SOI=FF D8 @', data.find(b'\xff\xd8'), ' EOI=FF D9 @', data.find(b'\xff\xd9'))
    prev = 0
    for seg, (off, m) in enumerate(ms):
        print('  RST %02X seg=%2d seg_bytes=%4d' % (m, seg, off - prev))
        prev = off
    if ms:
        print('  尾部 bytes=%d' % (len(data) - prev))

base = load('base6007.jpg')
fifo = load('fifo2.jpg')

seg_report('base(6007)', base)
seg_report('fifo2(6447)', fifo)

# 首个差异点 + 差异块统计
n = min(len(base), len(fifo))
p = 0
while p < n and base[p] == fifo[p]:
    p += 1
print('=' * 70)
print('首个差异 offset=%d (0x%X)' % (p, p))
sm = difflib.SequenceMatcher(None, base, fifo, autojunk=False)
ops = [o for o in sm.get_opcodes() if o[0] != 'equal']
ins = sum(j2-j1 for t,i1,i2,j1,j2 in ops if t=='insert')
dele = sum(i2-i1 for t,i1,i2,j1,j2 in ops if t=='delete')
print('差异块=%d insert=%d delete=%d' % (len(ops), ins, dele))
for t,i1,i2,j1,j2 in ops[:16]:
    print('  %-7s A[%4d:%4d](%3d) B[%4d:%4d](%3d) A=%s B=%s' %
          (t,i1,i2,i2-i1,j1,j2,j2-j1,
           ' '.join('%02x'%b for b in base[i1:min(i2,i1+8)]),
           ' '.join('%02x'%b for b in fifo[j1:min(j2,j1+8)])))
