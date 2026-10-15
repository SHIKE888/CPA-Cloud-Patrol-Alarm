#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_link.py —— 验证 FPGA -> MIPI x4 -> RK 链路是否「比特精确」

前提: FPGA 侧 system_top.v 里 `JPEG_TEST_SRC = 1'b1` (发出线性递增测试载荷)。
      测试源约定「**线上**帧内第 k 个字节恒等于 (k & 0xFF)」。

⚠ 第一版脚本的坑 (已踩过, 记录在此避免重犯)
-------------------------------------------
直接把 V4L2 抓到的缓冲当成线序去比, 结果 99.6% 不匹配, 一度以为链路坏了。
实际上 **RKCIF 会做 CSI-2 解包**: 线上是 YUYV 交织 [Y0 U Y1 V], 落到内存是
NV16 平面 [Y 平面][UV 平面]。这个重排会把线性斜坡变成:

    Y[2i]  = 4i        Y[2i+1] = 4i+2      (取线序 位置 0, 2)
    UV[2i] = 4i+1      UV[2i+1] = 4i+3     (取线序 位置 1, 3)

于是 Y 平面是步长 2 的斜坡 (0,2,4,...), UV 平面是 (1,3,5,...)。
现象很有迷惑性: 每 256 字节才偶然撞对一次, 匹配率恰好 0.39%,
且"匹配的字节数"正好等于 帧字节数/256 = 16200。

所以本脚本会**同时检验多种假设**, 并明确报告哪一个成立。

用法:
    sh /root/rk/deploy/run_verify.sh              # 推荐 (自动让出设备)
    /opt/miniforge3/envs/mlk-ov/bin/python verify_link.py [/dev/video22] [帧数]
"""
import os
import subprocess
import sys

import numpy as np

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/video22"
NFRAME = int(sys.argv[2]) if len(sys.argv) > 2 else 3
W, H, BPP = 1920, 1080, 2
FRAME_BYTES = W * H * BPP          # 4,147,200
PLANE = W * H                      # 2,073,600 (Y 平面 / UV 平面各半)
RAW = "/tmp/_verify_frame.bin"


def grab(n):
    """用 v4l2-ctl 抓 n 帧原始数据 (绕开 OpenCV 的 MPLANE 协商问题)"""
    cmd = ["v4l2-ctl", "-d", DEV,
           "--set-fmt-video=width=%d,height=%d,pixelformat=NV16" % (W, H),
           "--stream-mmap", "--stream-count=%d" % n, "--stream-to=" + RAW]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode != 0:
        print("v4l2-ctl 失败:")
        print(p.stdout.decode("utf-8", "replace"))
        return None
    if not os.path.exists(RAW):
        return None
    return np.fromfile(RAW, dtype=np.uint8)


# ============================================================================
#  「内存序 -> 线序」的候选映射
# ============================================================================
def idx_identity(n):
    """假设 1: 驱动不做重排, 内存序 == 线序"""
    return np.arange(n, dtype=np.int64)


def idx_yuyv2nv16(n, swap_uv=False):
    """假设 2: 线序 YUYV [Y0 U Y1 V] -> NV16 平面 [Y...][UV...]

    Y 平面取线序偶数位置 (0,2,4,...), UV 平面取奇数位置 (1,3,5,...)。
    swap_uv=True 时认为线上是 [Y0 V Y1 U]。

    ⚠ 必须**按帧取模** (k % FRAME_BYTES): Y/UV 的分界点每帧重置。
      测试源每帧都从 0 重新计数, 所以每帧的映射规则完全相同。
      若按整段缓冲算, 只有第 1 帧是对的 —— 这个坑也踩过。
    """
    k = np.arange(n, dtype=np.int64) % FRAME_BYTES
    is_y = k < PLANE
    wy = 2 * k                                   # Y 平面第 k 个 <- 线序 2k
    j = k - PLANE                                # UV 平面内序号
    pair = j >> 1
    if swap_uv:
        wuv = 4 * pair + np.where((j & 1) == 0, 3, 1)
    else:
        wuv = 4 * pair + np.where((j & 1) == 0, 1, 3)
    return np.where(is_y, wy, wuv)


HYPOS = [
    ("1. 恒等 (内存序 == 线序)", idx_identity, {}),
    ("2. YUYV->NV16  [Y0 U Y1 V]", idx_yuyv2nv16, {"swap_uv": False}),
    ("3. YUYV->NV16  [Y0 V Y1 U]", idx_yuyv2nv16, {"swap_uv": True}),
]


def main():
    print("=" * 66)
    print(" FPGA -> MIPI x4 -> RK 链路比特精确性验证")
    print(" 设备 %s   每帧 %d 字节 (%dx%d x%d)" % (DEV, FRAME_BYTES, W, H, BPP))
    print("=" * 66)

    buf = grab(NFRAME)
    if buf is None:
        print("抓帧失败 —— 确认 FPGA 已烧录 JPEG_TEST_SRC=1 的固件, 且设备没被占用")
        return 1

    total = len(buf)
    print("抓到 %d 字节 = %.2f 帧" % (total, total / float(FRAME_BYTES)))
    if total < FRAME_BYTES:
        print("!! 不足一帧, 上游可能没在发数")
        return 1

    nf = total // FRAME_BYTES
    data = buf[:nf * FRAME_BYTES]

    # ---- 原始数据长相 ----
    print("\n抓到数据前 24 字节: " + " ".join("%02X" % b for b in data[:24]))
    print("线序期望前 24 字节: " + " ".join("%02X" % (k & 0xFF) for k in range(24)))
    print("Y  平面前 16 字节   : " + " ".join("%02X" % b for b in data[:16]))
    print("UV 平面前 16 字节   : " + " ".join("%02X" % b for b in data[PLANE:PLANE + 16]))

    # ---- 逐假设检验 ----
    print("\n" + "-" * 66)
    results = []
    for name, fn, kw in HYPOS:
        idx = fn(len(data), **kw)
        exp = (idx & 0xFF).astype(np.uint8)
        match = int((data == exp).sum())
        r = dict(name=name, fn=fn, kw=kw, exp=exp, match=match,
                 bad=len(data) - match,
                 rate=100.0 * match / len(data))
        results.append(r)
        print("  %-28s 匹配 %10d / %10d  (%9.4f%%)"
              % (name, match, len(data), r['rate']))
    print("-" * 66)

    best = max(results, key=lambda r: r['rate'])
    print("\n>>> 最佳假设: %s  (匹配率 %.4f%%)" % (best['name'], best['rate']))

    if best['bad'] == 0:
        print("""
    结论: **链路比特精确** —— 全 %d 帧 / %d 字节零误差。

    这证明了:
      · CSI-2 4 lane 传输没有丢字节 / 重复 / 错位
      · 帧起始 (FS) 与帧结束 (FE) 判断正确
      · D-PHY 采样裕量足够 (眼图正常)
      · RK 侧的字节重排规则已确知 —— 后续写 JPEG 码流时可以照此逆推

    下一步: 把 system_top.v 里 JPEG_TEST_SRC 置回 1'b0, 接真正的编码器。"""
              % (nf, len(data)))
        return 0

    # ---- 未到 100%: 继续定位 ----
    print("\n仍不匹配 %d 字节 (%.4f%%)" % (best['bad'], 100.0 - best['rate']))
    bad = np.flatnonzero(data != best['exp'])
    if len(bad):
        print("  首个: 第 %d 字节  实测 0x%02X  期望 0x%02X"
              % (bad[0], data[bad[0]], best['exp'][bad[0]]))
        ny = int((bad < PLANE).sum())
        print("  落在 Y 平面 %d 个, UV 平面 %d 个" % (ny, len(bad) - ny))
        if nf > 1:
            print("  逐帧不匹配数:")
            for i in range(nf):
                seg = data[i * FRAME_BYTES:(i + 1) * FRAME_BYTES]
                e = best['exp'][:FRAME_BYTES]
                print("    帧 %d: %d" % (i, int((seg != e).sum())))
        if best['fn'] is idx_identity:
            rows = np.unique(bad // W)
        else:
            rows = np.unique((bad % PLANE) // W)
        print("  涉及行数 %d / %d" % (len(rows), nf * H))
        if len(rows) <= 12:
            print("  行号: %s" % rows[:12].tolist())

    print("\n建议: 把本输出发回来。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
