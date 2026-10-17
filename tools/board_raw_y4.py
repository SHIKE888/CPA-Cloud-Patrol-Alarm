import cv2
import numpy as np

h, w = 2160, 3840
d = np.fromfile("/tmp/raw4k3.nv16", np.uint8)
y = d[:h * w].reshape(h, w)
cv2.imwrite("/tmp/raw4k3_y.jpg", y, [cv2.IMWRITE_JPEG_QUALITY, 92])
print(y.shape, float(y.mean()), float(y.std()))
