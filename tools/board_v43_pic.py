import cv2
import numpy as np

d = np.fromfile("/tmp/raw4k.nv16", np.uint8)[: 3840 * 2160].reshape(2160, 3840)
y = cv2.resize(d, (1280, 720), interpolation=cv2.INTER_AREA)
lo, hi = np.percentile(y, 2), np.percentile(y, 99)
y = np.clip((y.astype(np.float32) - lo) * 255.0 / (hi - lo + 1e-6), 0, 255).astype(np.uint8)
cv2.putText(y, "V43 4K raw  per-row shift = 0", (16, 40), cv2.FONT_HERSHEY_SIMPLEX, 1.0, 255, 2)
cv2.imwrite("/tmp/v43_4k.jpg", y, [cv2.IMWRITE_JPEG_QUALITY, 92])
print("ok")
