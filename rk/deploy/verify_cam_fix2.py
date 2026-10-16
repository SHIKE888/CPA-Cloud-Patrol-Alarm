#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验收 v2: 逐次采样, 并带 I2C 坏读重试。

1) 增益在**低曝光**下测 (满曝光时画面已经饱和, 看不出增益差异)
2) 压力测试逐次打印 CAM_WR_CNT/CAM_BUSY, 定位那次非法读 (CAM_BUSY=127)
"""
import fcntl
import json
import subprocess
import time
import urllib.request

ADDR, BUS = 0x40, 9
I2C_SLAVE = 0x0703
PY = "/opt/miniforge3/envs/mlk-ov/bin/python"
B = "http://127.0.0.1:9012"

f = open("/dev/i2c-%d" % BUS, "r+b", buffering=0)


def rd(reg):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg]))
    return f.read(1)[0]


def rdv(reg, n=5):
    """带重试的读: 5 次取众数, 避免单次坏读"""
    vals = [rd(reg) for _ in range(n)]
    return max(set(vals), key=vals.count)


def wr(reg, val):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg, val & 0xFF]))


def cnt():
    return rdv(0xD0) | (rdv(0xD1) << 8)


def busy():
    return rdv(0xD2)


def post(d):
    req = urllib.request.Request(B + "/api/fpga", method="POST",
                                 data=json.dumps(d).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode()).get("message")


MEAN = ("import cv2;i=cv2.imread('/tmp/v2.jpg',0);"
        "print('%.1f'%i.mean() if i is not None else '-1')")


def bright():
    subprocess.run(["curl", "-s", "-m", "15", "--output", "/tmp/v2.jpg",
                    B + "/snapshot.jpg"], check=False)
    return float(subprocess.run([PY, "-c", MEAN], capture_output=True,
                                text=True).stdout.strip() or -1)


def setexp(ms):
    post({"cam_exp_ms": ms})
    time.sleep(1.2)


print("=" * 62)
print(" 1. 增益 A/B  —— 在低曝光下测 (给增益留出头空间)")
print("=" * 62)
setexp(1.5)
post({"cam_gain_db": 0}); time.sleep(1.2)
b0 = bright()
setexp(1.5)
post({"cam_gain_db": 18}); time.sleep(1.2)
b18 = bright()
post({"cam_gain_db": 36}); time.sleep(1.2)
b36 = bright()
print("  exp=1.5ms  增益  0dB -> 亮度 %.1f" % b0)
print("  exp=1.5ms  增益 18dB -> 亮度 %.1f" % b18)
print("  exp=1.5ms  增益 36dB -> 亮度 %.1f" % b36)
print("  => %s" % ("✅ 增益有效" if b36 - b0 > 15 else "❌ 增益几乎没效果 (差 %.1f)" % (b36 - b0)))

print()
print("=" * 62)
print(" 2. ★ 逐次采样的连续改参压力测试 ★")
print("=" * 62)
post({"cam_exp_ms": 16.6, "cam_gain_db": 14.4, "ev": 0})
time.sleep(1.5)
w0 = cnt()
print("  起始 CAM_WR_CNT = %d  CAM_BUSY = %d" % (w0, busy()))
print()
print("   次  写入后立即                             1.5s 后")
bad = 0
for i in range(1, 21):
    ms = 4.0 + (i % 12)
    try:
        m = post({"cam_exp_ms": ms})
    except Exception as e:
        m = "!! %s" % e
    b_imm, w_imm = busy(), cnt()
    time.sleep(1.5)
    b_lat, w_lat = busy(), cnt()
    mark = ""
    if b_lat != 0 or not (0 <= w_lat < 60000):
        mark = "   <-- 异常"
        bad += 1
    print("  #%-2d  exp=%-5.1f  busy=%3d cnt=%-3d  |  busy=%d cnt=%-3d%s"
          % (i, ms, b_imm, w_imm, b_lat, w_lat, mark))

w1 = cnt()
print()
print("  结束 CAM_WR_CNT = %d   净增 = %d  (20 次改动, 每次 3 字节写入)" % (w1, w1 - w0))
print("  异常次数 = %d" % bad)
print("  => %s" % ("✅ 链路健康" if (w1 > w0 and bad == 0)
                   else "⚠ 需要进一步查 (净增 %d, 异常 %d)" % (w1 - w0, bad)))

print()
print("=" * 62)
print(" 3. 恢复默认")
print("=" * 62)
post({"cam_exp_ms": 16.6, "cam_gain_db": 14.4, "ev": 0})
time.sleep(2)
print("  CAM_WR_CNT=%d CAM_BUSY=%d  亮度=%.1f" % (cnt(), busy(), bright()))
f.close()
