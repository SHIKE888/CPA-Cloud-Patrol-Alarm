#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""决定性实验: 写 CAM_TRIG(0xC9) 必然让 cam_param 的 need_send 为真, 然后高速轮询 0xD2。

如果 CAM_BUSY 起来了 -> cam_param 在跑, 只是之前 cam_exp_ms 的写没触发它。
如果 CAM_BUSY 一直是 0  -> cam_param 根本没在工作(或 busy 恒 1 被误读)。
"""
import fcntl
import time

ADDR, BUS = 0x40, 9
I2C_SLAVE = 0x0703

f = open("/dev/i2c-%d" % BUS, "r+b", buffering=0)


def rd(reg):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg]))
    return f.read(1)[0]


def wr(reg, val):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg, val]))


def cnt():
    return rd(0xD0) | (rd(0xD1) << 8)


print("写前: CAM_TRIG=%d  CAM_BUSY=%d  CAM_WR_CNT=%d" % (rd(0xC9), rd(0xD2), cnt()))

newtrig = (rd(0xC9) + 7) & 0xFF
t0 = time.time()
wr(0xC9, newtrig)
print("已写 CAM_TRIG=%d" % newtrig)

hi = lo = None
n = 0
while time.time() - t0 < 3.0:
    b = rd(0xD2)
    n += 1
    el = (time.time() - t0) * 1000
    if b and hi is None:
        hi = el
    if hi is not None and not b:
        lo = el
        break

print("采样 %d 次" % n)
print("CAM_BUSY 上升 = %s ms" % ("%.1f" % hi if hi is not None else "** 未出现 **"))
print("CAM_BUSY 回落 = %s ms" % ("%.1f" % lo if lo is not None else "未回落"))
print("写后: CAM_TRIG=%d  CAM_BUSY=%d  CAM_WR_CNT=%d (delta=%d)"
      % (rd(0xC9), rd(0xD2), cnt(), cnt() - 2))
f.close()
