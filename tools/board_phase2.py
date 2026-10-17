import numpy as np


def load(path, w, h):
    d = np.fromfile(path, np.uint8)
    return d[: w * h].reshape(h, w).astype(np.float32)


def pshift(a, y0, y1):
    W = a.shape[1]
    fa = np.fft.rfft(a[y0] - a[y0].mean())
    fb = np.fft.rfft(a[y1] - a[y1].mean())
    cc = fb * np.conj(fa)
    cc /= np.abs(cc) + 1e-9
    r = np.fft.irfft(cc, n=W)
    i = int(np.argmax(r))
    if i > W // 2:
        i -= W
    return i, float(r.max())


a4 = load("/tmp/raw4k.nv16", 3840, 2160)
print("4K per-row drift:", pshift(a4, 500, 501))

# 若每行 +2px，则相隔 1920 行应完全重合
for y in [300, 600, 900]:
    print("4K row %d vs %d -> shift,peak =" % (y, y + 1920), pshift(a4, y, y + 1920))

a1 = load("/tmp/raw1080.nv16", 1920, 1080)
print("1080p per-row drift:", pshift(a1, 300, 301), pshift(a1, 600, 601))
