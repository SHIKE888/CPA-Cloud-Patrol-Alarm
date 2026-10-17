import numpy as np

h, w = 2160, 3840
raw = np.fromfile("/tmp/raw4k_4.nv16", np.uint8)
fs = h * w * 2
print("frames", raw.size // fs)
for i in range(raw.size // fs):
    f = raw[i * fs:(i + 1) * fs].reshape(h, w * 2)
    y = f[:, 0::2].astype(np.int32)
    means = [int(y[j].mean()) for j in (1000, 1060, 1079, 1080, 1081, 1100, 2100)]
    print(i, means)
