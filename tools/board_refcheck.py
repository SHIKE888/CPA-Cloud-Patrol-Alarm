#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
board_refcheck.py —— 用「软件参考模型」逐像素核对 FPGA 预处理输出

思路：同一静止场景先抓一张“原图”，再抓各处理模式；
      在软件里按 RTL 完全相同的公式复算一遍，然后：
        1) 先搜整数位移 (dx,dy) 把两者对齐  -> 对齐后还对不上就是「算法本身错」
        2) 对齐后算：增益最优比例、残差 RMS、相关系数
        3) 分上/中/下三条带分别量残差 -> 能发现“只有某几行错”
        4) 单色检查：R-G / B-G 的均值与最大值
        5) 直方图：由对齐后的 (in,out) 对反推经验 LUT，检查单调性/最大斜率/映射跨度
      全程无量纲、可视化无关。

用法：
  /opt/miniforge3/envs/mlk-ov/bin/python board_refcheck.py --frames 12
"""
import argparse
import json
import time
import urllib.request

import numpy as np
import cv2

BASE = {"PP_EN": 0, "ADV_MODE": 0,
        "ADV_SOBEL_SH": 4, "ADV_PREW_SH": 4, "ADV_LAP_SH": 4,
        "ADV_THRESH": 128, "ADV_MORPH_SEL": 0, "ADV_MORPH_TH": 128,
        "ADV_EMBOSS_GAIN": 4, "ADV_EMBOSS_BIAS": 128,
        "BASIC_EN": 0, "BASIC_GRAY": 0, "BASIC_GAUSS": 8, "BASIC_KER": 1,
        "BASIC_HE": 255, "BASIC_HE_CLIP": 8, "BASIC_CONTRAST": 4}

CASES = [
    # 标签,             寄存器增量,                                          软件模型
    ("原图",            {},                                                    "none"),
    ("高斯3x3_s8",      {"BASIC_EN": 2, "BASIC_GAUSS": 8, "BASIC_KER": 0},     "gauss1"),
    ("高斯5x5_s8",      {"BASIC_EN": 2, "BASIC_GAUSS": 8, "BASIC_KER": 1},     "gauss2"),
    ("高斯7x7_s8",      {"BASIC_EN": 2, "BASIC_GAUSS": 8, "BASIC_KER": 2},     "gauss3"),
    ("高斯3x3_s4",      {"BASIC_EN": 2, "BASIC_GAUSS": 4, "BASIC_KER": 0},     "gauss1_mix4"),
    ("直方图_255",      {"BASIC_EN": 4, "BASIC_HE": 255, "BASIC_HE_CLIP": 8},  "he"),
    ("Sobel_g4",        {"PP_EN": 1, "ADV_MODE": 1, "ADV_SOBEL_SH": 4},        "sobel4"),
    ("Sobel_g8",        {"PP_EN": 1, "ADV_MODE": 1, "ADV_SOBEL_SH": 8},        "sobel8"),
    ("Prewitt_g4",      {"PP_EN": 1, "ADV_MODE": 7, "ADV_PREW_SH": 4},         "prew4"),
    ("Prewitt_g8",      {"PP_EN": 1, "ADV_MODE": 7, "ADV_PREW_SH": 8},         "prew8"),
]

MAXSH = 12          # 位移搜索范围 ±12 像素


# ---------------------------------------------------------------- IO
def api(host, payload, timeout=8):
    req = urllib.request.Request("http://%s/api/fpga" % host,
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def grab(host, n, timeout=25.0):
    r = urllib.request.urlopen(urllib.request.Request(
        "http://%s/stream" % host, headers={"User-Agent": "refcheck"}), timeout=timeout)
    out, buf, t0 = [], b"", time.time()
    try:
        while len(out) < n and time.time() - t0 < timeout:
            c = r.read(65536)
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
                img = cv2.imdecode(np.frombuffer(buf[s:e + 2], np.uint8), cv2.IMREAD_COLOR)
                buf = buf[e + 2:]
                if img is not None:
                    out.append(img)
                    if len(out) >= n:
                        break
    finally:
        r.close()
    return out


def avg(host, payload, frames):
    api(host, dict(BASE))
    time.sleep(0.3)
    if payload:
        api(host, payload)
    time.sleep(1.6 if payload.get("BASIC_EN", 0) & 4 else 0.6)
    fr = grab(host, frames + 3)[3:]
    if len(fr) < 3:
        raise RuntimeError("帧数不足")
    h = min(f.shape[0] for f in fr)
    w = min(f.shape[1] for f in fr)
    fr = [f[:h, :w] for f in fr]
    return np.mean(fr, axis=0).astype(np.float32), len(fr)


# ---------------------------------------------------------------- 模型
def blur_pass(img):
    """3x3 二项式 [1 2 1]x[1 2 1]/16, 与 RTL 相同: (sum+8)>>4 逐通道"""
    k = np.array([1, 2, 1], dtype=np.float32)
    out = np.zeros_like(img)
    p = np.pad(img, ((1, 1), (1, 1), (0, 0)), mode="edge")
    acc = np.zeros_like(img)
    for dy in range(3):
        for dx in range(3):
            acc += k[dy] * k[dx] * p[dy:dy + img.shape[0], dx:dx + img.shape[1]]
    return np.floor((acc + 8.0) / 16.0)


_CACHE = {}


def model_ref(name, ref):
    """返回软件参考输出（float32, 与 ref 同尺寸同通道）"""
    if name in _CACHE:
        return _CACHE[name]
    g = cv2.cvtColor(ref, cv2.COLOR_BGR2GRAY).astype(np.float32)
    b, gr, r = ref[:, :, 0], ref[:, :, 1], ref[:, :, 2]

    if name == "none":
        out = ref.copy()
    elif name.startswith("gauss"):
        n = {"gauss1": 1, "gauss1_mix4": 1, "gauss2": 2, "gauss3": 3}[name]
        x = ref.copy()
        for _ in range(n):
            x = blur_pass(x)
        if name == "gauss1_mix4":          # 强度 4/8: 50% 混合
            x = np.floor((x + ref + 1) / 2.0)
        out = x
    elif name.startswith("sobel"):
        gain = 4.0 if name.endswith("4") else 8.0
        p = np.pad(g, 1, mode="edge")
        a0 = p[0:-2, 0:-2]; a1 = p[0:-2, 1:-1]; a2 = p[0:-2, 2:]
        b0 = p[1:-1, 0:-2]; b1 = p[1:-1, 1:-1]; b2 = p[1:-1, 2:]
        c0 = p[2:, 0:-2];   c1 = p[2:, 1:-1];   c2 = p[2:, 2:]
        gx = (a2 + 2 * b2 + c2) - (a0 + 2 * b0 + c0)
        gy = (c0 + 2 * c1 + c2) - (a0 + 2 * a1 + a2)
        mag = np.abs(gx) + np.abs(gy)
        v = np.clip(np.floor(mag * gain / 4.0), 0, 255)
        out = np.dstack([v, v, v])
    elif name.startswith("prew"):
        gain = 4.0 if name.endswith("4") else 8.0
        p = np.pad(g, 1, mode="edge")
        a0 = p[0:-2, 0:-2]; a1 = p[0:-2, 1:-1]; a2 = p[0:-2, 2:]
        b0 = p[1:-1, 0:-2]; b1 = p[1:-1, 1:-1]; b2 = p[1:-1, 2:]
        c0 = p[2:, 0:-2];   c1 = p[2:, 1:-1];   c2 = p[2:, 2:]
        px = (a2 + b2 + c2) - (a0 + b0 + c0)
        py = (c0 + c1 + c2) - (a0 + a1 + a2)
        mag = np.abs(px) + np.abs(py)
        v = np.clip(np.floor(mag * gain / 4.0), 0, 255)
        out = np.dstack([v, v, v])
    else:                                  # he: 不建模型，单独反推 LUT
        out = ref.copy()
    _CACHE[name] = out.astype(np.float32)
    return _CACHE[name]


# ---------------------------------------------------------------- 对齐
def best_shift(a, b, rng=MAXSH):
    """找让 a[y+dy, x+dx] ≈ b[y, x] 的整数位移。先 1/4 降采样粗搜，再原图精修 ±2。"""
    h, w = a.shape[:2]
    ga = cv2.cvtColor(a, cv2.COLOR_BGR2GRAY)
    gb = cv2.cvtColor(b, cv2.COLOR_BGR2GRAY)
    sa = cv2.resize(ga, (w // 4, h // 4), interpolation=cv2.INTER_AREA)
    sb = cv2.resize(gb, (w // 4, h // 4), interpolation=cv2.INTER_AREA)
    r4 = max(2, rng // 4)
    m = r4 + 2
    core = sb[m:sb.shape[0] - m, m:sb.shape[1] - m]
    best, cdx, cdy = None, 0, 0
    for dy in range(-r4, r4 + 1):
        for dx in range(-r4, r4 + 1):
            cand = sa[m + dy:sa.shape[0] - m + dy, m + dx:sa.shape[1] - m + dx]
            d = float(np.mean((cand - core) ** 2))
            if best is None or d < best:
                best, cdx, cdy = d, dx, dy

    m = rng + 3
    core = gb[m:h - m, m:w - m]
    best, bdx, bdy = None, cdx * 4, cdy * 4
    for dy in range(cdy * 4 - 3, cdy * 4 + 4):
        for dx in range(cdx * 4 - 3, cdx * 4 + 4):
            cand = ga[m + dy:h - m + dy, m + dx:w - m + dx]
            d = float(np.mean((cand - core) ** 2))
            if best is None or d < best:
                best, bdx, bdy = d, dx, dy
    return bdx, bdy, best


def shifted(img, dx, dy, h, w, m):
    return img[m + dy:h - m + dy, m + dx:w - m + dx]


# ---------------------------------------------------------------- 主流程
def report_case(label, mdl, ref, cur, frames):
    h, w = cur.shape[:2]
    dx, dy, mse0 = best_shift(ref, cur)
    m = MAXSH + 4
    rc = ref[m:h - m, m:w - m]
    cc = shifted(cur, dx, dy, h, w, m)
    gc = cv2.cvtColor(cc, cv2.COLOR_BGR2GRAY)
    gr = cv2.cvtColor(rc, cv2.COLOR_BGR2GRAY)

    b, g, r = cc[:, :, 0], cc[:, :, 1], cc[:, :, 2]
    rg = r - g
    bg = b - g

    print("\n==== %s ====  (n=%d 帧平均)" % (label, frames))
    print("  对齐位移 dx=%+d dy=%+d   （对齐后灰度 MSE=%.2f）" % (dx, dy, mse0))
    print("  单色检查  R-G: mean=%+.2f max|.|=%.0f   |   B-G: mean=%+.2f max|.|=%.0f"
          % (rg.mean(), np.abs(rg).max(), bg.mean(), np.abs(bg).max()))

    if mdl != "he":
        ref_out = model_ref(mdl, ref)
        # ★ 边缘图与“原图”做 MSE 对齐没有意义（内容完全不同）。
        #   改成与**软件模型输出**对齐 —— 两者统计特性相同，位移才可测。
        mdx, mdy, mmse = best_shift(ref_out, cur)
        ro = shifted(ref_out, mdx, mdy, h, w, m)
        rgr = cv2.cvtColor(ro, cv2.COLOR_BGR2GRAY)
        num = float((gc * rgr).sum())
        den = float((rgr * rgr).sum()) + 1e-9
        gain = num / den
        res = gc - gain * rgr
        rms = float(np.sqrt((res ** 2).mean()))
        corr = float(np.corrcoef(gc.ravel(), rgr.ravel())[0, 1])
        rel = rms / (float(rgr.std()) + 1e-6)
        print("  vs 软件模型: 位移 dx=%+d dy=%+d   对齐后MSE=%.2f" % (mdx, mdy, mmse))
        print("     增益=%.3f  残差RMS=%.2f (=模型的 %.1f%%)  相关=%.4f"
              % (gain, rms, rel * 100.0, corr))
        # 分带残差
        hh = gc.shape[0] // 3
        bands = [float(np.sqrt((res[i * hh:(i + 1) * hh] ** 2).mean())) for i in range(3)]
        print("     分带残差RMS 上/中/下 = %.2f / %.2f / %.2f" % tuple(bands))
        print("     输出灰度: mean=%.1f std=%.1f p1..p99=%.0f..%.0f"
              % (gc.mean(), gc.std(), np.percentile(gc, 1), np.percentile(gc, 99)))
    else:
        # 反推经验 LUT：按输入亮度分桶取输出中位数
        lo = np.floor(gr).astype(np.int32)
        lut = np.full(256, np.nan)
        cnt = np.zeros(256, dtype=np.int64)
        for v in range(256):
            msk = lo == v
            n = int(msk.sum())
            cnt[v] = n
            if n > 200:
                lut[v] = float(np.median(gc[msk]))
        ok = ~np.isnan(lut)
        idx = np.where(ok)[0]
        if len(idx) < 8:
            print("  有效亮度桶太少，无法反推 LUT")
            return
        L = lut[idx]
        d = np.diff(L)
        print("  经验 LUT: 覆盖输入 %d..%d -> 输出 %.0f..%.0f"
              % (idx[0], idx[-1], L[0], L[-1]))
        print("  斜率: max=%.2f  min=%.2f  负斜率段数=%d（应 >=0）"
              % (d.max() if len(d) else 0, d.min() if len(d) else 0, int((d < -0.5).sum())))
        print("  输出灰度: mean=%.1f std=%.1f p1..p99=%.0f..%.0f"
              % (gc.mean(), gc.std(), np.percentile(gc, 1), np.percentile(gc, 99)))
        # 陡段定位
        if len(d):
            k = int(np.argmax(d))
            print("  最陡处: 输入 %d→%d 输出 %.0f→%.0f (斜率 %.1f)"
                  % (idx[k], idx[k + 1], L[k], L[k + 1], d[k]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1:9012")
    ap.add_argument("--frames", type=int, default=12)
    ap.add_argument("--only", default="")
    a = ap.parse_args()

    st = json.loads(urllib.request.urlopen("http://%s/api/fpga" % a.host, timeout=8).read())
    print("板子 VER=0x%04X" % int(st.get("status", {}).get("VER") or 0))

    print("抓原图 ...")
    ref, nf = avg(a.host, {}, a.frames)
    print("  原图 mean=%.1f  R-G=%+.2f B-G=%+.2f"
          % (cv2.cvtColor(ref, cv2.COLOR_BGR2GRAY).mean(),
             (ref[:, :, 2] - ref[:, :, 1]).mean(), (ref[:, :, 0] - ref[:, :, 1]).mean()))

    want = [s.strip() for s in a.only.split(",") if s.strip()] if a.only else None
    for label, payload, mdl in CASES:
        if label == "原图":
            continue
        if want and not any(label.startswith(k) for k in want):
            continue
        try:
            cur, nf = avg(a.host, payload, a.frames)
        except Exception as e:
            print("\n==== %s ====  抓取失败: %s" % (label, e))
            continue
        report_case(label, mdl, ref, cur, nf)

    api(a.host, dict(BASE))
    print("\n已恢复全关。")


if __name__ == "__main__":
    main()
