import cv2
import numpy as np

W, H = 1920, 1080
a = np.fromfile("/tmp/raw1080.nv16", np.uint8)[: W * H].reshape(H, W)          # 1080p 参考
d = np.fromfile("/tmp/raw4k.nv16", np.uint8)
b4 = d[: 3840 * 2160].reshape(2160, 3840)
b = cv2.resize(b4, (W, H), interpolation=cv2.INTER_AREA)                      # 4K 缩小一半

# 拼成左右对比
def stretch(x):
    lo, hi = np.percentile(x, 1), np.percentile(x, 99.5)
    return np.clip((x.astype(np.float32) - lo) * 255.0 / (hi - lo + 1e-6), 0, 255).astype(np.uint8)

side = np.hstack([stretch(a), stretch(b)])
cv2.imwrite("/tmp/cmp_side.jpg", cv2.resize(side, (1920, 540)))
cv2.imwrite("/tmp/cmp_1080.png", stretch(a))
cv2.imwrite("/tmp/cmp_4k.png", stretch(b))

orb = cv2.ORB_create(6000)
ka, da = orb.detectAndCompute(stretch(a), None)
kb, db = orb.detectAndCompute(stretch(b), None)
bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
m = sorted(bf.match(da, db), key=lambda x: x.distance)
print("kp", len(ka), len(kb), "matches", len(m))
good = [x for x in m if x.distance < 50][:800]
print("good", len(good))
if len(good) >= 20:
    pa = np.float32([ka[x.queryIdx].pt for x in good])
    pb = np.float32([kb[x.trainIdx].pt for x in good])
    M, inl = cv2.estimateAffine2D(pa, pb, ransacReprojThreshold=4.0)
    print("affine 1080->4k(downscaled):")
    print(np.array2string(M, precision=5))
    print("inliers", int(inl.sum()), "/", len(good))
    kk, dd = cv2.findHomography(pa, pb, cv2.RANSAC, 4.0)
    print("homography:")
    print(np.array2string(kk, precision=5))
