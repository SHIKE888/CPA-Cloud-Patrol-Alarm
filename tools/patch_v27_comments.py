#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V27 注释/文档同步：把 4K 的 4503/533/7.18us/1485Mbps 档 描述改为 3449/861/11.60us/891Mbps 档。

只做纯注释与文档文本替换，不动任何代码逻辑。
"""
import io
import os
import sys

ROOT = r"C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415"

# (相对路径, [(old, new), ...])
JOBS = [
    (r"fpga\uisrc\03_ip\ui_imx415_cfg\ui_imx415_reg.v", [
        ("//  关键: 4K VMAX = 0x1197 = 4503 行, HMAX = 0x215 = 533",
         "//  V27: 4K 改用 891Mbps 档 ->  SYS_MODE=5, HMAX=861(0x35D), VMAX=3449(0xD79)"),
        ("//        => cam_param.v  的 VMAX 也必须跟着模式变 (2283 <-> 4503)。",
         "//        => cam_param.v 的 VMAX 也必须跟着模式变 (2283 <-> 3449)。\n"
         "//  为什么不再用厂商的 1485Mbps 档: 手册 P48 显示 4K all-pixel 有多档,\n"
         "//  891Mbps(1H=861clk) 同样满足 25fps; 且与 1080p 同速率后 D-PHY RX 无需变速,\n"
         "//  也避开了 >=1440Mbps 才出现的 initial deskew burst。"),
    ]),
    (r"fpga\uisrc\01_rtl\ctrl\cam_param.v", [
        ("//      4K    (all-pixel)  : VMAX = 4503 行, 行周期 533/74.25MHz = 7.18us",
         "//      4K    (all-pixel)  : VMAX = 3449 行, 行周期 861/74.25MHz = 11.60us (V27)"),
        ("input  wire [19:0] i_vmax,       // 帧长(行): binning 2283, 4K 4503",
         "input  wire [19:0] i_vmax,       // 帧长(行): binning 2283, 4K 3449 (V27)"),
    ]),
    (r"rk\web\mipi_webstream.py", [
        ("#     4K    (all-pixel)  : VMAX=4503, 行周期 533/74.25MHz = 7.18us",
         "# V27: 4K    (all-pixel)  : VMAX=3449, 行周期 861/74.25MHz = 11.60us (891Mbps 档)"),
        ("# V24: 曝光换算要跟传感器读出模式走 (4K 的 VMAX 是 4503, 不是 2283)",
         "# V24/V27: 曝光换算要跟传感器读出模式走 (4K 的 VMAX 是 3449, 不是 2283)"),
        ("# V24: 曝光换算要跟模式走 —— 4K 的 VMAX=4503/ 行周期7.18us,",
         "# V24/V27: 曝光换算要跟模式走 —— 4K 的 VMAX=3449/ 行周期11.60us,"),
    ]),
]


def main():
    bad = 0
    for rel, subs in JOBS:
        p = os.path.join(ROOT, rel)
        t = io.open(p, encoding="utf-8", newline="").read()
        for old, new in subs:
            if old not in t:
                print("  !! 未找到 (%s): %s" % (rel, old[:60]))
                bad += 1
                continue
            t = t.replace(old, new, 1)
        io.open(p, "w", encoding="utf-8", newline="").write(t)
        print("  ok %s" % rel)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
