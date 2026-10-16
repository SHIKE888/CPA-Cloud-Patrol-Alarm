#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""稳定性测试: 固定一个曝光值, 连续抓 30 帧看亮度是否稳定。

如果亮度在 "设定值" 和 "初值(8/0x30)" 之间来回跳 -> 主表周期性重写把参数覆盖了。
"""
import fcntl
import subprocess
import time

ADDR, BUS = 0x40, 9
I2C_SLAVE = 0x0703
PY = "/opt/miniforge3/envs/mlk-ov/bin/python"
B = "http://127.0.0.1:9012"

f = open("/dev/i2c-%d" % BUS, "r+b", buffering=0)


def wr(reg, val):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg, val & 0xFF]))


def rd(reg):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg]))
    return f.read(1)[0]


def set_exp(shr0):
    wr(0xC2, (shr0 >> 16) & 0x0F)
    wr(0xC1, (shr0 >> 8) & 0xFF)
    wr(0xC0, shr0 & 0xFF)


MEAN = ("import cv2;i=cv2.imread('/tmp/s.jpg',0);"
        "print('%.0f'%i.mean() if i is not None else '-1')")


def bright():
    subprocess.run(["curl", "-s", "-m", "10", "--output", "/tmp/s.jpg",
                    B + "/snapshot.jpg"], check=False)
    return subprocess.run([PY, "-c", MEAN], capture_output=True,
                          text=True).stdout.strip()


for tag, shr0 in (("SHR0=1187 (约8ms, 中等亮)", 1187),
                  ("SHR0=100  (约16ms, 很亮)", 100),
                  ("SHR0=2275 (极短, 很暗)", 2275)):
    set_exp(shr0)
    time.sleep(1.0)
    vals = []
    t0 = time.time()
    while time.time() - t0 < 4.0:
        vals.append(bright())
    print("%s" % tag)
    print("   30 帧亮度: %s" % " ".join(vals))
    nums = [float(v) for v in vals if v != "-1"]
    if nums:
        print("   min=%.0f max=%.0f 波动=%.0f  -> %s"
              % (min(nums), max(nums), max(nums) - min(nums),
                 "稳定" if max(nums) - min(nums) < 15 else "** 在跳变! **"))
    print()

set_exp(1187)
f.close()
