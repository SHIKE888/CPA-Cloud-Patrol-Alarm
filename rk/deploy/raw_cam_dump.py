#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""原始 dump 0xC0..0xE5 + 关键状态, 用于判断 FPGA 里到底有没有 cam_param 参数区。"""
import fcntl
import json
import urllib.request

ADDR, BUS = 0x40, 9
I2C_SLAVE = 0x0703

NAMES = {
    0xC0: "CAM_EXP_L", 0xC1: "CAM_EXP_M", 0xC2: "CAM_EXP_H", 0xC3: "CAM_GAIN",
    0xC4: "EV_BIAS", 0xC5: "WB_R", 0xC6: "WB_B", 0xC7: "FPS_DIV",
    0xC8: "ROI_PCT", 0xC9: "CAM_TRIG",
    0xD0: "CAM_WR_CNT_L", 0xD1: "CAM_WR_CNT_H", 0xD2: "CAM_BUSY",
    0xD3: "CAM_ID", 0xE0: "RES_MODE",
}

f = open("/dev/i2c-%d" % BUS, "r+b", buffering=0)
fcntl.ioctl(f, I2C_SLAVE, ADDR)


def rd(reg):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg]))
    return f.read(1)[0]


print("=== 原始寄存器 dump ===")
for a in sorted(NAMES):
    v = rd(a)
    print("  0x%02X %-16s = 0x%02X (%d)" % (a, NAMES[a], v, v))

print()
print("=== 其他探测 ===")
for a in (0x0A, 0xB0, 0xA9, 0xAA, 0xB8, 0xB9):
    print("  0x%02X = 0x%02X" % (a, rd(a)))

print()
print("=== /api/fpga 全量相机字段 ===")
with urllib.request.urlopen("http://127.0.0.1:9012/api/fpga", timeout=10) as r:
    j = json.loads(r.read().decode())
for k in ("CAM_ID", "CAM_WR_CNT", "CAM_BUSY", "cam_exp_ms", "cam_gain_db", "ev",
          "CAM_EXP_L", "CAM_EXP_M", "CAM_EXP_H", "CAM_GAIN", "CAM_TRIG", "res_mode"):
    if k in j:
        print("  %-14s = %s" % (k, j[k]))
print()
print("  全部键: " + ", ".join(sorted(j.keys())))

f.close()
