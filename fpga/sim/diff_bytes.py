# 逐字节 diff：ddr4/基准(o_ready_down=1'b1) vs FIFO 版输出
import difflib, sys

def load(p):
    with open(p, 'rb') as f:
        return f.read()

def hx(bs, lo, hi):
    return ' '.join('%02x' % b for b in bs[lo:hi])

def cmp(tag, a, b, show_ops=24):
    print('=' * 78)
    print('%s: 基准A=%d B=%d  delta=%+d' % (tag, len(a), len(b), len(b) - len(a)))
    n = min(len(a), len(b))
    p = 0
    while p < n and a[p] == b[p]:
        p += 1
    su = 0
    while su < (n - p) and a[len(a) - 1 - su] == b[len(b) - 1 - su]:
        su += 1
    print('  公共前缀=%d 字节   公共后缀=%d 字节' % (p, su))
    if p == len(a) == len(b):
        print('  ==> 完全一致')
        return p, su
    print('  首个差异 offset = %d (0x%X)' % (p, p))
    lo = max(0, p - 16)
    hi = min(n, p + 16)
    print('  基准A[%d:%d] = %s' % (lo, hi, hx(a, lo, hi)))
    print('  B    [%d:%d] = %s' % (lo, hi, hx(b, lo, hi)))
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    ops = [o for o in sm.get_opcodes() if o[0] != 'equal']
    ins = sum(j2 - j1 for t, i1, i2, j1, j2 in ops if t == 'insert')
    dele = sum(i2 - i1 for t, i1, i2, j1, j2 in ops if t == 'delete')
    rep_a = sum(i2 - i1 for t, i1, i2, j1, j2 in ops if t == 'replace')
    rep_b = sum(j2 - j1 for t, i1, i2, j1, j2 in ops if t == 'replace')
    print('  差异块数=%d  insert=%d B字节  delete=%d A字节  replace=%d/%d' %
          (len(ops), ins, dele, rep_a, rep_b))
    for t, i1, i2, j1, j2 in ops[:show_ops]:
        print('   %-7s A[%4d:%4d](%3d)  B[%4d:%4d](%3d)  A=%s  B=%s' %
              (t, i1, i2, i2 - i1, j1, j2, j2 - j1,
               hx(a, i1, min(i2, i1 + 10)), hx(b, j1, min(j2, j1 + 10))))
    return p, su

base = load('base6007.jpg')
s1 = load('s1.jpg')
v54 = load('v54.jpg')

cmp('STEP1 only-FIFO  vs 基准', base, s1)
cmp('V54 FIFO+early-rst vs 基准', base, v54)
cmp('V54 vs STEP1', s1, v54)
