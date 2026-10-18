import numpy as np
import cv2

W, H = 3840, 2160
TW, TH = 1728, 972
raw = np.fromfile("/tmp/raw4k.nv16", np.uint8)[: W * H * 2]
y = raw[: W * H].reshape(H, W)
c = raw[W * H:].reshape(H, W // 2, 2)
ys = cv2.resize(y, (TW, TH), interpolation=cv2.INTER_LINEAR)
cs = cv2.resize(c, (TW // 2, TH), interpolation=cv2.INTER_LINEAR)
cs12 = np.ascontiguousarray(cs[::2])
out = np.concatenate([ys.reshape(-1), cs12.reshape(-1)])
out.tofile("/tmp/f1728.nv12")
print("wrote", out.size, "expect", TW * TH * 3 // 2)
