#!/opt/miniforge3/envs/mlk-ov/bin/python
# 看 v4l2 buffer 里非零数据到底分布在什么位置
import subprocess, time
import numpy as np, cv2

subprocess.run(["systemctl","stop","mipi-webstream"], capture_output=True)
time.sleep(1.5)
cap = cv2.VideoCapture("/dev/video22", cv2.CAP_V4L2)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920); cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
try: cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
except Exception: pass
cap.set(cv2.CAP_PROP_BUFFERSIZE, 4)

got = 0
while got < 3:
    ok, f = cap.read()
    if not ok or f is None:
        time.sleep(0.05); continue
    got += 1
    a = f.reshape(-1).view(np.uint8)
    n = a.size
    print("=== frame %d  size=%d ===" % (got, n))

    # 每 64KB 的零比例
    blk = 64 * 1024
    print("  64KB 块零比例:")
    line = "   "
    nz_blocks = []
    for i in range(0, n, blk):
        seg = a[i:i+blk]
        z = (seg == 0).mean()
        line += " %4.2f" % z
        if z < 0.999: nz_blocks.append(i // blk)
        if (i // blk + 1) % 12 == 0:
            print(line); line = "   "
    if line.strip(): print(line)

    print("  非零块索引(前40): %s" % nz_blocks[:40])
    print("  非零块总数: %d / %d" % (len(nz_blocks), (n + blk - 1)//blk))

    # 第一个非零字节的位置
    nzi = np.nonzero(a)[0]
    if nzi.size:
        first = int(nzi[0]); last = int(nzi[-1])
        print("  首个非零字节偏移=%d  末个非零字节偏移=%d  跨度=%d" % (first, last, last-first))
        print("  该处起 64 字节: %s" % a[first:first+64].tobytes().hex())
        # 从首个非零处开始搜 marker
        buf = a[first:].tobytes()
        for pat, nm in [(b"\xff\xd8","FFD8"), (b"\xff\xd9","FFD9"), (b"\xff\xe0","FFE0"), (b"\xff\xdb","FFDB"), (b"\xff\xc0","FFC0"), (b"\xff\xc4","FFC4")]:
            c = 0; i = 0
            while True:
                j = buf.find(pat, i)
                if j < 0: break
                c += 1; i = j + 1
            print("    %s = %d" % (nm, c))
    else:
        print("  !! 整个 buffer 全零")

    # 每行的非零像素数统计（按 3840 字节/行 = 1920x2 的 NV16 stride）
    stride = 3840
    rows = n // stride
    row_nz = np.array([np.count_nonzero(a[r*stride:(r+1)*stride]) for r in range(0, rows, max(1, rows//24))])
    print("  按行抽样非零字节数(每行 %d B): %s" % (stride, row_nz.tolist()))

cap.release()
subprocess.run(["systemctl","start","mipi-webstream"], capture_output=True)
print("\nweb restarted")
