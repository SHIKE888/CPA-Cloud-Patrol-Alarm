#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
board_he_aeloop.py —— 验证「HE 与 AE(自动曝光) 构成闭环」这个假设

现象：HE 一开，整帧亮度会在几十帧里来回摆动（实测极差 60 级、30 帧内符号翻转 9 次），
      而"原图"和"对比度"完全稳定（极差 0.1）。
怀疑：AE 的统计取样点在 HE **之后**，于是
        HE 提亮 → AE 认为过亮 → 降曝光 → 画面变暗 → HE 再拉 → 来回振荡。
      这能解释"直方图自添加以来一直闪"。

做法：逐帧同时记录 「整帧平均亮度」与「CAM_EXP / CAM_GAIN」，看它们是否同步振荡。
  · 曝光/增益跟着亮度一起摆  -> 闭环成立，根因在 AE 取样位置
  · 曝光/增益不动、只有亮度摆 -> 根因在 HE 自身

用法：
  /opt/miniforge3/envs/mlk-ov/bin/python board_he_aeloop.py --frames 24 --case he
"""
import argparse
import json
import time
import urllib.request

import numpy as np
import cv2

API = "/api/fpga"
BASE = {"PP_EN": 0, "ADV_MODE": 0,
        "BASIC_EN": 0, "BASIC_GRAY": 0, "BASIC_GAUSS": 8, "BASIC_KER": 1,
        "BASIC_HE": 255, "BASIC_HE_CLIP": 8, "BASIC_CONTRAST": 4}

CASES = {
    "off": {},
    "he":  {"BASIC_EN": 4, "BASIC_HE": 255, "BASIC_HE_CLIP": 8},
    "he0": {"BASIC_EN": 4, "BASIC_HE": 255, "BASIC_HE_CLIP": 0},
}


def call(host, payload=None):
    url = "http://%s%s" % (host, API)
    if payload is None:
        req = urllib.request.Request(url)
    else:
        req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def one_frame(host, timeout=15.0):
    r = urllib.request.urlopen(urllib.request.Request(
        "http://%s/stream" % host, headers={"User-Agent": "aeloop"}), timeout=timeout)
    buf = b""
    try:
        while True:
            c = r.read(65536)
            if not c:
                return None
            buf += c
            s = buf.find(b"\xff\xd8\xff")
            if s < 0:
                buf = buf[-2:]
                continue
            e = buf.find(b"\xff\xd9", s + 3)
            if e < 0:
                continue
            img = cv2.imdecode(np.frombuffer(buf[s:e + 2], np.uint8), cv2.IMREAD_GRAYSCALE)
            if img is not None:
                return float(img.mean())
    finally:
        r.close()


def run(host, case, n):
    call(host, dict(BASE))
    time.sleep(0.35)
    if CASES[case]:
        call(host, CASES[case])
    time.sleep(2.5)

    rows = []
    for i in range(n):
        lum = one_frame(host)
        st = call(host).get("regs", {})
        exp = int(st.get("CAM_EXP_L", 0)) | (int(st.get("CAM_EXP_M", 0)) << 8) | \
              (int(st.get("CAM_EXP_H", 0)) << 16)
        gain = int(st.get("CAM_GAIN", 0))
        rows.append((lum, exp, gain))

    L = np.array([r[0] for r in rows], dtype=float)
    E = np.array([r[1] for r in rows], dtype=float)
    G = np.array([r[2] for r in rows], dtype=float)

    def flips(a, thr):
        d = np.diff(a)
        d = d[np.abs(d) > thr]
        return int((np.diff(np.sign(d)) != 0).sum()) if len(d) > 2 else 0

    print("\n==== case=%s ====" % case)
    print("  亮度   : " + " ".join("%5.1f" % v for v in L))
    print("  SHR0   : " + " ".join("%5d" % v for v in E))
    print("  CAM_GAIN: " + " ".join("%5d" % v for v in G))
    print("  亮度   极差=%.1f  符号翻转=%d" % (L.max() - L.min(), flips(L, 0.5)))
    print("  SHR0   极差=%d     符号翻转=%d" % (E.max() - E.min(), flips(E, 0)))
    print("  GAIN   极差=%d     符号翻转=%d" % (G.max() - G.min(), flips(G, 0)))
    if L.std() > 1e-6 and E.std() > 1e-6:
        # SHR0 大 = 曝光短 = 更暗，所以期望负相关
        print("  亮度 vs SHR0 相关系数 = %+.3f （若显著负相关 => AE 在追着亮度走）"
              % float(np.corrcoef(L, E)[0, 1]))
    if L.std() > 1e-6 and G.std() > 1e-6:
        print("  亮度 vs GAIN 相关系数 = %+.3f" % float(np.corrcoef(L, G)[0, 1]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1:9012")
    ap.add_argument("--frames", type=int, default=24)
    ap.add_argument("--case", default="he")
    a = ap.parse_args()
    st = call(a.host)
    print("板子 VER=0x%04X" % int(st.get("status", {}).get("VER") or 0))
    for c in a.case.split(","):
        run(a.host, c.strip(), a.frames)
    call(a.host, dict(BASE))
    print("\n已恢复全关。")


if __name__ == "__main__":
    main()
