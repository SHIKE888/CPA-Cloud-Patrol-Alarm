import numpy as np

d = np.fromfile("/tmp/raw4k.nv16", np.uint8)
a = d[: 3840 * 2160].reshape(2160, 3840).astype(np.float32)
a -= a.mean()

W = 3840
freq = np.fft.rfft(a, axis=1)


def shift_rows(y0, y1):
    """相邻行的循环相移 (像素)，负数=内容向左移"""
    A, B = freq[y0], freq[y1]
    cc = B * np.conj(A)
    cc /= np.abs(cc) + 1e-9
    r = np.fft.irfft(cc, n=W)
    i = int(np.argmax(r))
    if i > W // 2:
        i -= W
    return i


vals = []
for y0 in range(200, 2000, 50):
    s = shift_rows(y0, y0 + 1)
    vals.append(s)
vals = np.array(vals)
print("per-row shift samples:", vals[:40].tolist())
print("median %.2f  mean %.3f  std %.2f  min %d max %d"
      % (np.median(vals), vals.mean(), vals.std(), vals.min(), vals.max()))
