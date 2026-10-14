#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""enc_bench.py —— JPEG 编码能否靠多核并行突破 60fps

背景: RK3576 单线程 1080p JPEG 编码实测约 24ms/帧 -> 41.5fps, 到不了 60。
      本机 8 核 = 4x Cortex-A53@1.92GHz (cpu0-3) + 4x Cortex-A72@2.11GHz (cpu4-7)。

目的: 判断真正瓶颈是
      (a) CPU 总量不够  -> 必须把 JPEG 挪到 FPGA
      (b) 只是用了单核  -> 多进程并行就能到 60fps, 不用动 FPGA

方法: 用 v4l2-ctl 抓一帧真实画面 (绕开 OpenCV 的 MPLANE 协商问题),
      再在 N 个进程里各自反复编码同一帧, 测聚合帧率。
      若是 (b), 聚合帧率随 N 近似线性增长。

用法:
  pkill -f 'mipi_web[s]tream'
  /opt/miniforge3/envs/mlk-ov/bin/python enc_bench.py [/dev/video22] [质量]
"""
import multiprocessing as mp
import os
import subprocess
import sys
import time

import numpy as np

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/video22"
QUALITY = int(sys.argv[2]) if len(sys.argv) > 2 else 80
W, H = 1920, 1080
RAW = "/tmp/_frame_nv16.raw"


def grab_raw_frame():
    cmd = ["v4l2-ctl", "-d", DEV,
           "--set-fmt-video=width=%d,height=%d,pixelformat=NV16" % (W, H),
           "--stream-mmap", "--stream-count=1", "--stream-to=" + RAW]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(RAW) or os.path.getsize(RAW) < W * H * 2:
        return None
    return np.fromfile(RAW, dtype=np.uint8)[:W * H * 2]


def nv16_to_bgr(raw):
    """NV16 (Y 平面 + 交织 UV) -> BGR888, BT.601 整数式, 只为造一张真实图"""
    y_plane = raw[:W * H].reshape(H, W).astype(np.int16)
    uv = raw[W * H:].reshape(H, W // 2, 2).astype(np.int16)
    U = uv[:, :, 0] - 128
    V = uv[:, :, 1] - 128
    bgr = np.empty((H, W, 3), dtype=np.uint8)
    for k, off in ((0, (0, 1)), (1, (2, 3))):
        Y = y_plane[:, k::2] - 16
        R = (298 * Y + 409 * V + 128) >> 8
        G = (298 * Y - 100 * U - 208 * V + 128) >> 8
        B = (298 * Y + 516 * U + 128) >> 8
        bgr[:, k::2, 0] = np.clip(B, 0, 255)
        bgr[:, k::2, 1] = np.clip(G, 0, 255)
        bgr[:, k::2, 2] = np.clip(R, 0, 255)
    return bgr


def worker(args):
    idx, cpu, frame_bytes, shape, n_iter = args
    try:
        os.sched_setaffinity(0, {cpu})
    except Exception:
        pass
    import cv2
    frame = np.frombuffer(frame_bytes, dtype=np.uint8).reshape(shape)
    enc = [int(cv2.IMWRITE_JPEG_QUALITY), QUALITY]
    for _ in range(3):
        cv2.imencode(".jpg", frame, enc)          # 预热
    t0 = time.time()
    for _ in range(n_iter):
        ok, buf = cv2.imencode(".jpg", frame, enc)
    dt = time.time() - t0
    return (n_iter / dt, len(buf), dt / n_iter * 1000)


def run_parallel(nproc, frame, n_iter, cpus):
    shape = frame.shape
    fb = frame.tobytes()
    jobs = [(i, cpus[i % len(cpus)], fb, shape, n_iter) for i in range(nproc)]
    t0 = time.time()
    with mp.Pool(nproc) as pool:
        res = pool.map(worker, jobs)
    wall = time.time() - t0
    return sum(r[0] for r in res), res[0][1] / 1024.0, res[0][2], n_iter * nproc / wall


def main():
    txt = open("/proc/cpuinfo").read()
    n = txt.count("processor\t:")
    parts = sorted(set(l.split(":", 1)[1].strip()
                       for l in txt.splitlines() if l.startswith("CPU part")))
    print("CPU: %d 核, part=%s  (0xd03=Cortex-A53, 0xd08=Cortex-A72)" % (n, ",".join(parts)))
    import cv2
    print("cv2 %s" % cv2.__version__)

    print("\n抓一帧真实画面 (v4l2-ctl) ...")
    raw = grab_raw_frame()
    if raw is None:
        print("抓帧失败 —— 确认摄像头/FPGA 在跑, 且没有别的进程占用 " + DEV)
        return 1
    frame = nv16_to_bgr(raw)
    print("  %s  OK" % (frame.shape,))

    n_iter = 20
    print("\n=== 单进程基准 (绑 A72 core4) ===")
    total1, kb, ms, _ = run_parallel(1, frame, n_iter, [4])
    print("  1 进程 : %6.1f fps  (%.1f ms/帧, JPEG %.0f KB/帧)"
          % (total1, ms, kb))
    print("           网络带宽需求 %.1f Mbps @ %.0f fps"
          % (kb * 8 * 60 / 1000, 60))

    print("\n=== N 进程并行 (绑 A72 core4-7) ===")
    best = total1
    for k in (2, 3, 4):
        total, kb2, ms2, wall = run_parallel(k, frame, n_iter, [4, 5, 6, 7])
        best = max(best, total)
        print("  %d 进程 : %6.1f fps  加速比 %.2fx  (单进程 %.1f fps, %.1f ms/帧)"
              % (k, total, total / total1, 1.0 / (ms2 / 1000.0), ms2))

    print("\n=== 结论 ===")
    if best > 55:
        print("  并行编码可达 %.1f fps > 55" % best)
        print("  => 瓶颈是【单核】, 不是 CPU 总量。")
        print("     多进程并行编码就能到 1080p60, 不必把 JPEG 挪到 FPGA。")
    else:
        print("  并行编码只有 %.1f fps, 距离 60 还差 %.0f%%"
              % (best, (60 - best) / 60 * 100))
        print("  => CPU 总量是硬限制, 要让 RK 出 1080p60 JPEG 得靠 FPGA。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
