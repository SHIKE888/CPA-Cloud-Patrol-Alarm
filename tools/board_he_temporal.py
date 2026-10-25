#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
board_he_temporal.py —— 把「闪烁」和「噪点」分开量化（针对直方图均衡）

★ 为什么不能用"整帧平均亮度的标准差"当闪烁指标：
  LUT 一变，一部分亮度升、一部分降，整帧均值互相抵消 → 结构性低估。
  静态场景下真正该看的是**空间低通后的时域波动**：
    闪烁 = 大尺度区域亮度逐帧在动（人眼最敏感）
    噪点 = 小尺度像素级时域跳动

方法：
  1) 对每一帧做高斯低通（sigma=8 ≈ 32px 尺度）得到 lp，高通残差 hf = frame - lp
  2) flicker  = 各像素 lp 序列的时间标准差，再对像素取均值 / p95（单位：级）
  3) noise    = 相邻帧 hf 差的 RMS（单位：级）
  4) 分「收敛段」与「稳态段」两段统计 —— HE 的 LUT 是逐帧 IIR，前十几帧本来就在变
  5) 顺带记录整帧均值序列与符号翻转次数，判断是"单调收敛"还是"来回振荡"

用法：
  /opt/miniforge3/envs/mlk-ov/bin/python board_he_temporal.py --frames 30
"""
import argparse
import json
import time
import urllib.request

import numpy as np
import cv2

BASE = {"PP_EN": 0, "ADV_MODE": 0,
        "ADV_SOBEL_SH": 4, "ADV_PREW_SH": 4, "ADV_LAP_SH": 4,
        "BASIC_EN": 0, "BASIC_GRAY": 0, "BASIC_GAUSS": 8, "BASIC_KER": 1,
        "BASIC_HE": 255, "BASIC_HE_CLIP": 8, "BASIC_CONTRAST": 4}

CASES = [
    ("原图(基线)",              {}),
    ("HE255_clip8(默认)",       {"BASIC_EN": 4, "BASIC_HE": 255, "BASIC_HE_CLIP": 8}),
    ("HE255_clip0(不限)",       {"BASIC_EN": 4, "BASIC_HE": 255, "BASIC_HE_CLIP": 0}),
    ("HE255_clip32",            {"BASIC_EN": 4, "BASIC_HE": 255, "BASIC_HE_CLIP": 32}),
    ("HE128_clip8",             {"BASIC_EN": 4, "BASIC_HE": 128, "BASIC_HE_CLIP": 8}),
    ("灰度+HE255_clip8",        {"BASIC_EN": 5, "BASIC_HE": 255, "BASIC_HE_CLIP": 8}),
    ("高斯5x5+HE255_clip8",     {"BASIC_EN": 6, "BASIC_HE": 255, "BASIC_HE_CLIP": 8,
                                 "BASIC_GAUSS": 8, "BASIC_KER": 1}),
    ("对比度8(对照,应无闪烁)",  {"BASIC_EN": 8, "BASIC_CONTRAST": 8}),
]


def api(host, payload, timeout=8):
    req = urllib.request.Request("http://%s/api/fpga" % host,
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def grab(host, n, timeout=40.0):
    r = urllib.request.urlopen(urllib.request.Request(
        "http://%s/stream" % host, headers={"User-Agent": "hetemp"}), timeout=timeout)
    out, buf, t0 = [], b"", time.time()
    try:
        while len(out) < n and time.time() - t0 < timeout:
            c = r.read(262144)
            if not c:
                break
            buf += c
            while True:
                s = buf.find(b"\xff\xd8\xff")
                if s < 0:
                    buf = buf[-2:]
                    break
                e = buf.find(b"\xff\xd9", s + 3)
                if e < 0:
                    buf = buf[s:]
                    break
                img = cv2.imdecode(np.frombuffer(buf[s:e + 2], np.uint8), cv2.IMREAD_GRAYSCALE)
                buf = buf[e + 2:]
                if img is not None:
                    out.append(img.astype(np.float32))
                    if len(out) >= n:
                        break
    finally:
        r.close()
    return out


def analyse(label, frames):
    n = len(frames)
    h = min(f.shape[0] for f in frames)
    w = min(f.shape[1] for f in frames)
    F = np.stack([f[:h, :w] for f in frames])          # [n, h, w]

    lp = np.stack([cv2.GaussianBlur(f, (0, 0), 8) for f in F])
    hf = F - lp

    half = n // 2
    win = {"收敛段": slice(2, max(4, half)), "稳态段": slice(half, n)}

    means = F.reshape(n, -1).mean(1)
    d = np.diff(means)
    sign_flips = int((np.diff(np.sign(d[np.abs(d) > 0.05])) != 0).sum()) if len(d) > 2 else 0

    print("\n==== %s ====  n=%d 帧  %dx%d" % (label, n, w, h))
    print("  整帧均值序列: %.1f → %.1f   (极差 %.1f, 符号翻转 %d 次)"
          % (means[0], means[-1], means.max() - means.min(), sign_flips))
    print("  %-8s %10s %10s %10s %10s" % ("段", "闪烁(均值)", "闪烁(p95)", "噪点", "帧间Δlp"))
    for nm, sl in win.items():
        L = lp[sl]
        if L.shape[0] < 3:
            continue
        sd = L.std(axis=0)
        flick = float(sd.mean())
        flick95 = float(np.percentile(sd, 95))
        H = hf[sl]
        noise = float(np.sqrt(np.mean(np.diff(H, axis=0) ** 2)))
        dstep = float(np.abs(np.diff(L, axis=0)).mean())
        print("  %-8s %10.3f %10.3f %10.3f %10.3f" % (nm, flick, flick95, noise, dstep))
    return means


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1:9012")
    ap.add_argument("--frames", type=int, default=30)
    ap.add_argument("--only", default="")
    a = ap.parse_args()

    st = json.loads(urllib.request.urlopen("http://%s/api/fpga" % a.host, timeout=8).read())
    print("板子 VER=0x%04X  帧数=%d" % (int(st.get("status", {}).get("VER") or 0), a.frames))
    print("说明: 闪烁 = 空间低通(sigma8)后逐像素时间标准差(级); 噪点 = 高通残差相邻帧差 RMS(级)")

    want = [s.strip() for s in a.only.split(",") if s.strip()] if a.only else None
    for label, payload in CASES:
        if want and not any(label.startswith(k) for k in want):
            continue
        try:
            api(a.host, dict(BASE))
            time.sleep(0.35)
            if payload:
                api(a.host, payload)
            time.sleep(3.0)                 # 给 IIR 一点起步时间
            fr = grab(a.host, a.frames)
        except Exception as e:
            print("\n==== %s ====  失败: %s" % (label, e))
            continue
        if len(fr) < 8:
            print("\n==== %s ====  帧数不足(%d)" % (label, len(fr)))
            continue
        analyse(label, fr)

    api(a.host, dict(BASE))
    print("\n已恢复全关。")


if __name__ == "__main__":
    main()
