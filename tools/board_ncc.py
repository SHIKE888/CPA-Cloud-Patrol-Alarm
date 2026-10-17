import numpy as np


def load(p, w, h):
    return np.fromfile(p, np.uint8)[: w * h].reshape(h, w).astype(np.float32)


def ncc_shift(a, y0, y1, x0, x1, rng=40):
    r0 = a[y0, x0:x1]
    r1 = a[y1, x0:x1]
    r0 = r0 - r0.mean()
    r1 = r1 - r1.mean()
    den = np.sqrt((r0 * r0).sum() * (r1 * r1).sum()) + 1e-6
    best = (-9, 0)
    for s in range(-rng, rng + 1):
        if s >= 0:
            v = (r0[s:] * r1[: len(r1) - s]).sum()
        else:
            v = (r0[:s] * r1[-s:]).sum()
        v /= den
        if v > best[0]:
            best = (v, s)
    return best


a4 = load("/tmp/raw4k.nv16", 3840, 2160)
a1 = load("/tmp/raw1080.nv16", 1920, 1080)

print("== 4K, 纹理区 y1200-1500 x400-3400 ==")
for y in range(1200, 1500, 30):
    print(y, ["%.3f@%d" % ncc_shift(a4, y, y + 1, 400, 3400),
              "%.3f@%d" % ncc_shift(a4, y, y + 40, 400, 3400, 200)])

print("== 1080p, y600-900 x200-1700 ==")
for y in range(600, 900, 60):
    print(y, ["%.3f@%d" % ncc_shift(a1, y, y + 1, 200, 1700),
              "%.3f@%d" % ncc_shift(a1, y, y + 40, 200, 1700, 200)])
