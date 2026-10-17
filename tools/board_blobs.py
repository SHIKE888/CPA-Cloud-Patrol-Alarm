import cv2
import numpy as np

d = np.fromfile("/tmp/raw4k.nv16", np.uint8)
y = d[: 3840 * 2160].reshape(2160, 3840)

_, th = cv2.threshold(y, 170, 255, cv2.THRESH_BINARY)
n, lab, stats, cent = cv2.connectedComponentsWithStats(th, 8)
out = []
for i in range(1, n):
    x, yy, w, h, area = stats[i]
    if area > 3000:
        out.append((int(area), int(cent[i][0]), int(cent[i][1]), int(w), int(h)))
out.sort(key=lambda t: t[2])
for a, cx, cy, w, h in out:
    print("area=%6d  cx=%4d cy=%4d  w=%4d h=%3d" % (a, cx, cy, w, h))
print("count", len(out))
if len(out) >= 2:
    for i in range(1, len(out)):
        dx = out[i][1] - out[i - 1][1]
        dy = out[i][2] - out[i - 1][2]
        if dy:
            print("delta dx=%d dy=%d  -> px/row=%.3f" % (dx, dy, dx / dy))
