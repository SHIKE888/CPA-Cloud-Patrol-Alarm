#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""测量: 改一次摄像头参数后, FPGA 的 AE 链路(CAM_BUSY) 要走多久才完成。

用法: python3 /root/measure_cam_lat.py [新的曝光ms]
"""
import fcntl
import os
import sys
import time
import urllib.request
import json

ADDR = 0x40
BUS = 9
B = "http://127.0.0.1:9012"

I2C_SLAVE = 0x0703


def rd(f, reg):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg]))
    return f.read(1)[0]


def wr_cnt(f):
    return rd(f, 0xD0) | (rd(f, 0xD1) << 8)


def main():
    ms = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
    f = open("/dev/i2c-%d" % BUS, "r+b", buffering=0)
    fcntl.ioctl(f, I2C_SLAVE, ADDR)

    b0, w0 = rd(f, 0xD2), wr_cnt(f)
    print("改前:   CAM_BUSY=%d  CAM_WR_CNT=%d" % (b0, w0))

    # 先测一次单寄存器 I2C 读的耗时
    t = time.time()
    for _ in range(50):
        rd(f, 0xD2)
    t_read = (time.time() - t) / 50 * 1000
    print("单次 I2C 读寄存器耗时: %.2f ms  (轮询粒度上限)" % t_read)

    req = urllib.request.Request(
        B + "/api/fpga", method="POST",
        data=json.dumps({"cam_exp_ms": ms}).encode(),
        headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=15) as r:
        msg = json.loads(r.read().decode())
    t_post = time.time() - t0
    print("POST 返回: %s  (耗时 %.1f ms, 此时 FPGA 已在跑)" %
          (msg.get("message"), t_post * 1000))

    busy_hi = None
    busy_lo = None
    w_last = w0
    n = 0
    while time.time() - t0 < 5.0:
        b = rd(f, 0xD2)
        n += 1
        el = (time.time() - t0) * 1000
        if b and busy_hi is None:
            busy_hi = el
        if busy_hi is not None and not b and busy_lo is None:
            busy_lo = el
            break

    w1 = wr_cnt(f)
    print("采样 %d 次" % n)
    print("CAM_BUSY 上升: %s ms" % ("%.1f" % busy_hi if busy_hi is not None else "未观测到"))
    print("CAM_BUSY 回落: %s ms" % ("%.1f" % busy_lo if busy_lo is not None else "未观测到(5s 内没落回)"))
    print("改后:   CAM_WR_CNT=%d  (delta=%d)" % (w1, w1 - w0))
    f.close()


if __name__ == "__main__":
    main()
