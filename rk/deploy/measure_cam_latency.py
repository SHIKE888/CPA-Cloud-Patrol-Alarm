#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""测真实延迟: 从写 CAM_EXP 到画面亮度变化, 需要多久。

做法: 先设为很暗(SHR0=2275 -> 亮度 ~7), 再设为很亮(SHR0=100 -> 亮度 ~135),
      然后以最快速度反复抓帧, 记录亮度第一次跨过阈值的时间。
这一步绕开 1ms 看门狗 —— 无论 AE 握手成功与否, 画面变了就说明参数到传感器了。
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


def set_exp(shr0):
    wr(0xC2, (shr0 >> 16) & 0x0F)
    wr(0xC1, (shr0 >> 8) & 0xFF)
    wr(0xC0, shr0 & 0xFF)


MEAN = ("import cv2,sys;i=cv2.imread('/tmp/l.jpg',0);"
        "print('%.1f'%i.mean() if i is not None else '-1')")


def bright():
    subprocess.run(["curl", "-s", "-m", "10", "--output", "/tmp/l.jpg",
                    B + "/snapshot.jpg"], check=False)
    return float(subprocess.run([PY, "-c", MEAN], capture_output=True,
                                text=True).stdout.strip() or -1)


# 抓一帧的耗时
t = time.time()
for _ in range(5):
    bright()
print("单次抓帧+算亮度耗时: %.0f ms" % ((time.time() - t) / 5 * 1000))

print("\n[1] 先设为很暗 SHR0=2275 ...")
set_exp(2275)
time.sleep(1.5)
print("    亮度 = %.1f" % bright())

print("[2] 切到很亮 SHR0=100, 立刻开始抓帧计时:")
t0 = time.time()
first = None
for i in range(60):
    v = bright()
    el = (time.time() - t0) * 1000
    print("    t=%7.1fms  亮度=%.1f" % (el, v))
    if v > 60 and first is None:
        first = el
        break
print("    => 亮度跨过阈值用时: %s ms"
      % ("%.0f" % first if first is not None else "60 帧内没等到"))

print("\n[3] 反向: 切回很暗 SHR0=2275")
t0 = time.time()
first = None
for i in range(60):
    v = bright()
    el = (time.time() - t0) * 1000
    print("    t=%7.1fms  亮度=%.1f" % (el, v))
    if v < 60 and first is None:
        first = el
        break
print("    => 变暗用时: %s ms"
      % ("%.0f" % first if first is not None else "60 帧内没等到"))

# 复原
set_exp(1187)
f.close()
