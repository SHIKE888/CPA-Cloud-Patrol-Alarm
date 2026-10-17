import cv2
import numpy as np

W, H = 3840, 2160
y = np.fromfile("/tmp/raw4k.nv16", np.uint8)[: W * H].reshape(H, W)


def stretch(a):
    lo, hi = np.percentile(a, 2), np.percentile(a, 99)
    return np.clip((a.astype(np.float32) - lo) * 255.0 / (hi - lo + 1e-6), 0, 255).astype(np.uint8)


def deshear(img, k):
    """每一行循环左移 k*y 像素; k>0 用来抵消"内容随行右移" """
    out = np.empty_like(img)
    rows = np.arange(H)
    shifts = (k * rows) % W
    for i in range(H):
        out[i] = np.roll(img[i], -int(shifts[i]))
    return out


ks = [-4, -3, -2, -1, 0, 1, 2, 3, 4]
tiles = []
for k in ks:
    t = cv2.resize(stretch(deshear(y, k)), (640, 360), interpolation=cv2.INTER_AREA)
    cv2.putText(t, "k=%+d px/row" % k, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, 255, 2)
    tiles.append(t)

rows = [np.hstack(tiles[i * 3:(i + 1) * 3]) for i in range(3)]
cv2.imwrite("/tmp/sweep.jpg", np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 90])
print("done", len(ks))
