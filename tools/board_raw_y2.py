import cv2
import numpy as np

h, w = 2160, 3840
d = np.fromfile("/tmp/raw4k.nv16", np.uint8)
print("size", d.size, "expect", h * w * 2)
y = d[:h * w].reshape(h, w)
cv2.imwrite("/tmp/raw4k_y2.jpg", y, [cv2.IMWRITE_JPEG_QUALITY, 95])
print(y.shape, float(y.mean()), float(y.std()))
