#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""摄像头参数链路 最终验收 (覆盖全部 4 项 + 稳定性)

  1. 曝光 A/B
  2. 增益 A/B (必须在**低曝光**下测: 满曝光时画面已饱和, 看不出增益)
  3. 曝光补偿 EV (+3 夹住不变黑 / -3 变暗)
  4. 固定值稳定性 (30 帧)
  5. 连续改参 20 次压力测试
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
    v = [rd(reg) for _ in range(n)]
    return max(set(v), key=v.count)


def cnt():
    return rdv(0xD0) | (rdv(0xD1) << 8)


def post(d):
    req = urllib.request.Request(B + "/api/fpga", method="POST",
                                 data=json.dumps(d).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode()).get("message")


MEAN = ("import cv2;i=cv2.imread('/tmp/vf.jpg',0);"
        "print('%.1f'%i.mean() if i is not None else '-1')")


def bright():
    subprocess.run(["curl", "-s", "-m", "15", "--output", "/tmp/vf.jpg",
                    B + "/snapshot.jpg"], check=False)
    return float(subprocess.run([PY, "-c", MEAN], capture_output=True,
                                text=True).stdout.strip() or -1)


def setv(d, settle=1.3):
    post(d)
    time.sleep(settle)


fails = []

print("=" * 64)
print(" 1. 曝光 A/B")
print("=" * 64)
setv({"cam_gain_db": 14.4, "ev": 0, "cam_exp_ms": 0.5}); a = bright()
setv({"cam_exp_ms": 16.6});                               b = bright()
print("  0.5ms -> %.1f     16.6ms -> %.1f" % (a, b))
ok = b - a > 60
print("  => %s" % ("✅ 通过" if ok else "❌ 失败"))
if not ok: fails.append("曝光")

print()
print("=" * 64)
print(" 2. 增益 A/B  (低曝光 1.5ms, 满曝光下会饱和看不出)")
print("=" * 64)
setv({"cam_exp_ms": 1.5, "cam_gain_db": 0});  g0 = bright()
setv({"cam_gain_db": 18});                     g1 = bright()
setv({"cam_gain_db": 36});                     g2 = bright()
print("  0dB -> %.1f    18dB -> %.1f    36dB -> %.1f" % (g0, g1, g2))
ok = (g1 > g0 + 5) and (g2 > g1 + 5)
print("  => %s" % ("✅ 通过 (阶梯上升)" if ok else "❌ 失败"))
if not ok: fails.append("增益")

print()
print("=" * 64)
print(" 3. 曝光补偿 EV")
print("=" * 64)
setv({"cam_exp_ms": 16.6, "cam_gain_db": 14.4, "ev": 0}); e0 = bright()
setv({"ev": 3});                                           e3 = bright()
setv({"ev": -3});                                          em3 = bright()
setv({"ev": 0});                                           e0b = bright()
print("  EV 0 -> %.1f    +3 -> %.1f    -3 -> %.1f    (恢复 0) -> %.1f"
      % (e0, e3, em3, e0b))
ok3a = e3 > 1.0            # +3 不能再变黑
ok3b = em3 < e0 * 0.75     # -3 要明显变暗
print("  => %s" % ("✅ 通过 (+3 不变黑, -3 变暗)" if (ok3a and ok3b) else "❌ 失败"))
if not (ok3a and ok3b): fails.append("EV")

print()
print("=" * 64)
print(" 4. 稳定性 (固定值抓 30 帧)")
print("=" * 64)
for tag, d in (("16.6ms/14.4dB", {"cam_exp_ms": 16.6, "cam_gain_db": 14.4, "ev": 0}),
               ("1.5ms/14.4dB",  {"cam_exp_ms": 1.5,  "cam_gain_db": 14.4, "ev": 0})):
    setv(d, 1.5)
    vals = [bright() for _ in range(30)]
    lo, hi = min(vals), max(vals)
    print("  %-14s min=%.0f max=%.0f 波动=%.0f  %s"
          % (tag, lo, hi, hi - lo, "✅ 稳定" if hi - lo < 15 else "❌ 在跳变"))
    if hi - lo >= 15: fails.append("稳定性(%s)" % tag)

print()
print("=" * 64)
print(" 5. 连续改参 20 次压力测试")
print("=" * 64)
setv({"cam_exp_ms": 16.6, "cam_gain_db": 14.4, "ev": 0}, 1.5)
w0 = cnt()
for i in range(1, 21):
    post({"cam_exp_ms": 4.0 + (i % 12)})
time.sleep(3)
w1 = cnt()
print("  CAM_WR_CNT %d -> %d   净增 = %d   CAM_BUSY = %d" % (w0, w1, w1 - w0, rdv(0xD2)))
ok = w1 - w0 >= 20 and rdv(0xD2) == 0
print("  => %s" % ("✅ 通过" if ok else "❌ 失败"))
if not ok: fails.append("压力测试")

print()
print("=" * 64)
print(" 6. 恢复默认")
print("=" * 64)
setv({"cam_exp_ms": 16.6, "cam_gain_db": 14.4, "ev": 0,
      "wb_r_pct": 100, "wb_b_pct": 100, "roi_pct": 100}, 2)
print("  CAM_WR_CNT=%d  CAM_BUSY=%d  亮度=%.1f" % (cnt(), rdv(0xD2), bright()))

print()
print("=" * 64)
print(" 总结: %s" % ("🎉 全部 5 项通过" if not fails else "⚠ 失败项: " + ", ".join(fails)))
print("=" * 64)
f.close()
