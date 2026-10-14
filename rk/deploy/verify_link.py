#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_link.py —— 验证 FPGA -> MIPI x4 -> RK 链路是否「比特精确」

前提: FPGA 侧 system_top.v 里 `JPEG_TEST_SRC = 1'b1` (发出线性递增测试载荷)。

原理:
    测试源约定「帧内第 k 个字节恒等于 (k & 0xFF)」。
    抓一帧原始数据逐字节比对:
      · 全对            -> 链路比特精确, 可以接真编码器了
      · 整体平移 d 字节 -> 帧头对齐问题 (CSI-2 帧起始判断)
      · 零散错          
        - 集中在某些行  -> 行同步/丢包
        - 随机分布      -> 采样/眼图问题
    脚本会自动尝试识别"常量平移", 因为那是最常见的一种失配。

用法:
    pkill -f 'mipi_web[s]tream'          # 先让出 /dev/video22
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
    buf = np.fromfile(RAW, dtype=np.uint8)
    return buf


def expected_seq(n):
    """帧内第 k 字节应等于 (k & 0xFF)"""
    return (np.arange(n, dtype=np.uint16) & 0xFF).astype(np.uint8)


def find_offset(data, exp, span=4096):
    """尝试找一个常量平移 d, 使 data[k] == exp[(k+d) mod 256]。

    因为载荷是周期 256 的, 平移只能按 (d mod 256) 来判, 所以这里
    在 0..255 里搜, 用前 64KB 打分。
    """
    probe = min(len(data), 65536)
    a = data[:probe].astype(np.int16)
    best_d, best_hit = 0, -1
    for d in range(256):
        idx = (np.arange(probe, dtype=np.uint32) + d) & 0xFF
        hit = int((a == idx.astype(np.int16)).sum())
        if hit > best_hit:
            best_hit, best_d = hit, d
    return best_d, best_hit / float(probe)


def main():
    print("=" * 62)
    print(" FPGA -> MIPI x4 -> RK 链路比特精确性验证")
    print(" 设备 %s   每帧 %d 字节 (%dx%d x%d)" % (DEV, FRAME_BYTES, W, H, BPP))
    print("=" * 62)

    buf = grab(NFRAME)
    if buf is None:
        print("抓帧失败 —— 确认 FPGA 已烧录 JPEG_TEST_SRC=1 的固件, 且没有别的进程占用")
        return 1

    total = len(buf)
    print("抓到 %d 字节 = %.2f 帧" % (total, total / float(FRAME_BYTES)))
    if total < FRAME_BYTES:
        print("!! 不足一帧, 可能是上游没在发数")
        return 1

    # 只取整帧
    nf = total // FRAME_BYTES
    data = buf[:nf * FRAME_BYTES]
    exp = expected_seq(len(data))
    bad = np.flatnonzero(data != exp)

    print()
    if len(bad) == 0:
        print(">>> 完美: %d 帧 / %d 字节 全部匹配 <<<" % (nf, len(data)))
        print("    结论: CSI-2 传输比特精确, 可以接真正的 JPEG 编码器了。")
        return 0

    print("不匹配字节数: %d / %d  (%.4f%%)"
          % (len(bad), len(data), 100.0 * len(bad) / len(data)))
    print("首个不匹配位置: 第 %d 字节, 帧内第 %d 行第 %d 列"
          % (bad[0], bad[0] // (W * BPP), (bad[0] % (W * BPP))))
    print("实测值 0x%02X, 期望值 0x%02X" % (data[bad[0]], exp[bad[0]]))

    # ---- 是不是整体平移? ----
    d, score = find_offset(data, exp)
    print()
    print("常量平移检测: 最佳 d=%d, 匹配率 %.4f%%" % (d, score * 100))
    if score > 0.999:
        print("  => 数据内容是对的, 只是整体**平移了 %d 字节**。" % d)
        print("     属于帧对齐问题 (CSI-2 帧起始/首包判断), 不是数据损坏。")
    elif score > 0.5:
        print("  => 部分匹配, 更像是有**丢包或丢行**。")
    else:
        print("  => 基本对不上, 可能不是测试源在发数 (或固件没换成测试模式)。")

    # ---- 不匹配是否集中在行边界? ----
    row_of_bad = bad // (W * BPP)
    uniq_rows = np.unique(row_of_bad)
    print()
    print("不匹配涉及的行数: %d / %d" % (len(uniq_rows), nf * H))
    if len(uniq_rows) <= 20:
        print("  涉及行号: %s" % uniq_rows[:20].tolist())

    # ---- 每帧统计 ----
    if nf > 1:
        print()
        print("逐帧不匹配字节数:")
        for i in range(nf):
            seg = data[i * FRAME_BYTES:(i + 1) * FRAME_BYTES]
            nb = int((seg != expected_seq(FRAME_BYTES)).sum())
            print("  帧 %d: %d" % (i, nb))

    print()
    print("建议: 把本输出发回来, 我按现象定位是帧对齐、丢包还是采样问题。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
