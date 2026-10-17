import cv2
import numpy as np

a = cv2.imread("/tmp/s1080.png", cv2.IMREAD_GRAYSCALE)
b = cv2.imread("/tmp/s4k.png", cv2.IMREAD_GRAYSCALE)
print("shapes", a.shape, b.shape)

orb = cv2.ORB_create(8000)
ka, da = orb.detectAndCompute(a, None)
kb, db = orb.detectAndCompute(b, None)
print("kp", len(ka), len(kb))

bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
m = sorted(bf.match(da, db), key=lambda x: x.distance)[:1500]
pa = np.float32([ka[x.queryIdx].pt for x in m])
pb = np.float32([kb[x.trainIdx].pt for x in m])

M, inl = cv2.estimateAffine2D(pa, pb, ransacReprojThreshold=3.0)
print("affine (x,y)_1080 -> (x,y)_4k:")
print(np.array2string(M, precision=5))
print("inliers", int(inl.sum()), "/", len(m))

Minv, inl2 = cv2.estimateAffine2D(pb, pa, ransacReprojThreshold=3.0)
print("inverse:")
print(np.array2string(Minv, precision=5))

# 用纯平移（无仿射）残差对比：先算平均位移
d = pb[inl.ravel() == 1] - pa[inl.ravel() == 1]
print("mean shift", d.mean(axis=0), "std", d.std(axis=0))
