#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""干净 A/B: 直接写 CAM_EXP / CAM_GAIN 原始寄存器, 看 busy 起不起 + 画面亮不亮。

对比 web 的 /api/fpga 写法, 判断 cam_param.i_exp 到底有没有接上 CAM_EXP。
"""
import fcntl
import subprocess
import sys
import time

ADDR, BUS = 0x40, 9
I2C_SLAVE = 0x0703
PY = "/opt/miniforge3/envs/mlk-ov/bin/python"

f = open("/dev/i2c-%d" % BUS, "r+b", buffering=0)


def rd(reg):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg]))
    return f.read(1)[0]


def wr(reg, val):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg, val & 0xFF]))


def cnt():
    return rd(0xD0) | (rd(0xD1) << 8)


def set_exp(shr0):
    wr(0xC2, (shr0 >> 16) & 0x0F)
    wr(0xC1, (shr0 >> 8) & 0xFF)
    wr(0xC0, shr0 & 0xFF)


def bright():
    subprocess.run(["curl", "-s", "-m", "15", "--output", "/tmp/p.jpg",
                    "http://127.0.0.1:9012/snapshot.jpg"], check=False)
    out = subprocess.run([PY, "-c",
        "import cv2;i=cv2.imread('/tmp/p.jpg',0);"
        "print('%.1f'%i.mean() if i is not None else 'NA')"],
        capture_output=True, text=True).stdout.strip()
    return out


def watch(dur=1.5):
    """写完之后高速采样 busy/count"""
    t0 = time.time()
    hi = lo = None
    while time.time() - t0 < dur:
        b = rd(0xD2)
        el = (time.time() - t0) * 1000
        if b and hi is None:
            hi = el
        if hi is not None and not b:
            lo = el
            break
    return hi, lo


def case(tag, fn):
    print("--- %s ---" % tag)
    b0, w0 = rd(0xD2), cnt()
    fn()
    hi, lo = watch()
    w1 = cnt()
    print("   busy 上升=%s ms 回落=%s ms   cnt %d->%d"
          % ("%.1f" % hi if hi is not None else "无",
             "%.1f" % lo if lo is not None else "无", w0, w1))
    time.sleep(1.5)
    print("   画面平均亮度 = %s   (CAM_EXP=%d CAM_GAIN=%d)"
          % (bright(), rd(0xC0) | (rd(0xC1) << 8) | (rd(0xC2) << 16), rd(0xC3)))


print("起始: CAM_EXP=%d CAM_GAIN=%d busy=%d cnt=%d"
      % (rd(0xC0) | (rd(0xC1) << 8) | (rd(0xC2) << 16), rd(0xC3), rd(0xD2), cnt()))

case("曝光 SHR0=2275 (最长, 应很亮)", lambda: set_exp(2275))
case("曝光 SHR0=100  (极短, 应很暗)", lambda: set_exp(100))
case("曝光 SHR0=2275 (恢复, 应回亮)", lambda: set_exp(2275))
case("增益 CAM_GAIN=1   (应变暗)", lambda: wr(0xC3, 1))
case("增益 CAM_GAIN=100 (应变亮)", lambda: wr(0xC3, 100))
case("恢复 CAM_GAIN=48", lambda: wr(0xC3, 48))

f.close()
