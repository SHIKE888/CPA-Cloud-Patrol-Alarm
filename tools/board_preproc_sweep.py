#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
board_preproc_sweep.py —— 静态场景 + 控制变量，扫 FPGA 预处理模式/参数，连续抓帧做量化分析

设计原则（回答"到底是什么问题"）：
  · 场景静止 -> 相邻帧的任何差异都是**流水线自己制造的**（噪声/频闪/参数抖动）
  · 每次只改一个旋钮（控制变量），其余寄存器显式写回基线
  · 每个配置从 MJPEG 流里连续抓 N 帧，丢掉前几帧（改参数瞬间的在途帧）

指标：
  mean_lum        画面平均亮度
  flicker         各帧平均亮度的标准差  -> 整屏闪烁（频闪）
  tnoise          相邻帧逐像素 |diff| 的均值 -> 时域噪声
  tnoise_p99      同上 99 分位 -> 局部剧烈跳变（噪点）
  sstd            单帧空间标准差 -> 空间对比
  lapvar          Laplacian 方差 -> 边缘能量（锐不锐）
  r_g / b_g       R-G / B-G 均值 -> 偏色（单色算子应为 0）
  clip            亮度 =0 或 =255 的像素占比 -> 过曝/压黑

用法（板上）：
  /opt/miniforge3/envs/mlk-ov/bin/python board_preproc_sweep.py \
      --host 127.0.0.1:9012 --frames 16 --out /tmp/sweep.csv
"""
import argparse
import json
import sys
import time
import urllib.request

import numpy as np
import cv2

BASELINE = {
    "PP_EN": 0, "ADV_MODE": 0,
    "ADV_SOBEL_SH": 4, "ADV_THRESH": 128, "ADV_MORPH_SEL": 0,
    "ADV_MORPH_TH": 128, "ADV_LAP_SH": 4, "ADV_PREW_SH": 4,
    "ADV_EMBOSS_GAIN": 4, "ADV_EMBOSS_BIAS": 128,
    "BASIC_EN": 0, "BASIC_GRAY": 0, "BASIC_GAUSS": 8, "BASIC_KER": 1,
    "BASIC_HE": 255, "BASIC_HE_CLIP": 255, "BASIC_CONTRAST": 4,
}


def api(host, payload=None, timeout=8):
    url = "http://%s/api/fpga" % host
    if payload is None:
        req = urllib.request.Request(url)
    else:
        req = urllib.request.Request(
            url, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def grab_frames(host, n, timeout=20.0):
    """从 MJPEG 流连续抓 n 帧。返回 list[np.ndarray BGR]"""
    url = "http://%s/stream" % host
    req = urllib.request.Request(url, headers={"User-Agent": "sweep"})
    out, buf = [], b""
    t0 = time.time()
    r = urllib.request.urlopen(req, timeout=timeout)
    try:
        while len(out) < n and time.time() - t0 < timeout:
            chunk = r.read(65536)
            if not chunk:
                break
            buf += chunk
            while True:
                s = buf.find(b"\xff\xd8\xff")
                if s < 0:
                    buf = buf[-2:]
                    break
                e = buf.find(b"\xff\xd9", s + 3)
                if e < 0:
                    buf = buf[s:]
                    break
                jpg = buf[s:e + 2]
                buf = buf[e + 2:]
                img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
                if img is not None:
                    out.append(img)
                    if len(out) >= n:
                        break
    finally:
        try:
            r.close()
        except Exception:
            pass
    return out


def metrics(frames, ref=None):
    """对一串连续帧算指标。ref = 基线平均图（用于测位移）。"""
    h = min(f.shape[0] for f in frames)
    w = min(f.shape[1] for f in frames)
    frames = [f[:h, :w] for f in frames]
    grays = [cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.float32) for f in frames]

    means = np.array([g.mean() for g in grays])
    diffs = np.array([np.abs(grays[i] - grays[i - 1]) for i in range(1, len(grays))])
    tnoise = float(diffs.mean()) if diffs.size else 0.0
    tnoise_p99 = float(np.percentile(diffs, 99)) if diffs.size else 0.0

    avg = np.mean(grays, axis=0)
    sstd = float(avg.std())
    lapvar = float(cv2.Laplacian(avg, cv2.CV_32F, ksize=3).var())

    # 颜色：均值 + 对亮度的回归斜率
    b, g, r = cv2.split(np.mean([f[:h, :w] for f in frames], axis=0).astype(np.float32))
    r_g = float((r - g).mean())
    b_g = float((b - g).mean())
    y = g.ravel().astype(np.float64)
    yy = y - y.mean()
    den = float((yy * yy).sum()) or 1.0
    rg_slope = float(((r - g).ravel() - (r - g).mean()) @ yy / den) * 1000.0
    bg_slope = float(((b - g).ravel() - (b - g).mean()) @ yy / den) * 1000.0

    clip = float(((avg <= 1) | (avg >= 254)).mean() * 100.0)
    p1, p99 = np.percentile(avg, [1, 99])

    # 与基线帧的相位相关位移（检测整幅/部分错位、重影）
    dx = dy = 0.0
    ncc = 1.0
    if ref is not None:
        cs = min(512, h, w)
        y0, x0 = (h - cs) // 2, (w - cs) // 2
        a = ref[y0:y0 + cs, x0:x0 + cs].astype(np.float32)
        c = avg[y0:y0 + cs, x0:x0 + cs].astype(np.float32)
        try:
            (dx, dy), _ = cv2.phaseCorrelate(a, c)
        except Exception:
            pass
        a0 = a - a.mean()
        c0 = c - c.mean()
        ncc = float((a0 * c0).sum() / (np.sqrt((a0 * a0).sum() * (c0 * c0).sum()) + 1e-9))

    return dict(mean_lum=float(means.mean()), flicker=float(means.std()),
                tnoise=tnoise, tnoise_p99=tnoise_p99, sstd=sstd, lapvar=lapvar,
                r_g=r_g, b_g=b_g, rg_slope=rg_slope, bg_slope=bg_slope,
                clip=clip, p1_99=float(p99 - p1), dx=float(dx), dy=float(dy), ncc=ncc)


def api_params(host, payload, timeout=8):
    url = "http://%s/api/params" % host
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def run(host, nframes, settle, settle_he, only=None):
    st = api(host)
    ver = st.get("status", {}).get("VER")
    print("板子版本 VER=0x%04X  frames=%d" % (int(ver or 0), nframes))

    # (标签, {寄存器增量}, settle秒, 说明)
    cases = [
        ("A 基线(全关)",              {}, 0, ""),
        ("B 灰度",                    {"BASIC_EN": 1}, 0, "bit0"),
        ("C 高斯3x3 s8",              {"BASIC_EN": 2, "BASIC_GAUSS": 8, "BASIC_KER": 0}, 0, ""),
        ("D 高斯5x5 s8",              {"BASIC_EN": 2, "BASIC_GAUSS": 8, "BASIC_KER": 1}, 0, ""),
        ("D2 高斯5x5 s2",             {"BASIC_EN": 2, "BASIC_GAUSS": 2, "BASIC_KER": 1}, 0, ""),
        ("E 高斯7x7 s8",              {"BASIC_EN": 2, "BASIC_GAUSS": 8, "BASIC_KER": 2}, 0, ""),
        ("E2 高斯7x7 s2",             {"BASIC_EN": 2, "BASIC_GAUSS": 2, "BASIC_KER": 2}, 0, ""),
        ("F 高斯5x5 s4",              {"BASIC_EN": 2, "BASIC_GAUSS": 4, "BASIC_KER": 1}, 0, ""),
        ("G HE255 clip255",           {"BASIC_EN": 4, "BASIC_HE": 255, "BASIC_HE_CLIP": 255}, settle_he, ""),
        ("H HE255 clip8",             {"BASIC_EN": 4, "BASIC_HE": 255, "BASIC_HE_CLIP": 8}, settle_he, "强对比限制"),
        ("I HE128 clip255",           {"BASIC_EN": 4, "BASIC_HE": 128, "BASIC_HE_CLIP": 255}, settle_he, ""),
        ("J 对比度8",                 {"BASIC_EN": 8, "BASIC_CONTRAST": 8}, 0, ""),
        ("K 反色",                    {"BASIC_EN": 16}, 0, ""),
        ("L 灰度+HE",                 {"BASIC_EN": 5, "BASIC_HE": 255, "BASIC_HE_CLIP": 255}, settle_he, ""),
        ("M 高斯7x7+HE",              {"BASIC_EN": 6, "BASIC_GAUSS": 8, "BASIC_KER": 2, "BASIC_HE": 255}, settle_he, ""),
        ("N Sobel",                   {"PP_EN": 1, "ADV_MODE": 1}, 0, ""),
        ("N0 Sobel gain0",            {"PP_EN": 1, "ADV_MODE": 1, "ADV_SOBEL_SH": 0}, 0, ""),
        ("N8 Sobel gain8",            {"PP_EN": 1, "ADV_MODE": 1, "ADV_SOBEL_SH": 8}, 0, ""),
        ("O 阈值128",                 {"PP_EN": 1, "ADV_MODE": 2, "ADV_THRESH": 128}, 0, ""),
        ("P 形态-腐蚀",               {"PP_EN": 1, "ADV_MODE": 3, "ADV_MORPH_SEL": 0, "ADV_MORPH_TH": 128}, 0, ""),
        ("Q 中值",                    {"PP_EN": 1, "ADV_MODE": 4}, 0, ""),
        ("R 拉普拉斯",                {"PP_EN": 1, "ADV_MODE": 5}, 0, ""),
        ("S 浮雕",                    {"PP_EN": 1, "ADV_MODE": 6}, 0, ""),
        ("T Prewitt",                 {"PP_EN": 1, "ADV_MODE": 7}, 0, ""),
        # 白平衡作弊，证明颜色偏移来源
        ("U 原图+WB偏(R200%)",        {}, 0, "wb=200/100"),
        ("V Sobel+WB偏(R200%)",       {"PP_EN": 1, "ADV_MODE": 1}, 0, "wb=200/100"),
        ("W 灰度+WB偏(R200%)",        {"BASIC_EN": 1}, 0, "wb=200/100"),
    ]

    rows = []
    ref = None
    if only:
        keys = [s.strip() for s in only.split(",") if s.strip()]
        cases = [c for c in cases if any(c[0].startswith(k) for k in keys)]
        print("仅跑用例: %s" % ", ".join(c[0] for c in cases))
    for label, delta, st_extra, note in cases:
        wb = {"wb_r_pct": 200, "wb_b_pct": 100} if label.startswith(("U", "V", "W")) \
            else {"wb_r_pct": 100, "wb_b_pct": 100}
        # 1) 无条件写回基线（含 wb），保证控制变量
        p = dict(BASELINE)
        p.update(wb)
        try:
            api(host, p)
        except Exception as e:
            print("  !! 基线下发失败 %s" % e)
        time.sleep(0.35)
        # 2) 只改本用例的旋钮
        if delta:
            q = dict(delta)
            try:
                api(host, q)
            except Exception as e:
                print("  !! 用例下发失败 %s: %s" % (label, e))
                continue
        time.sleep(max(0.5, settle + st_extra))

        try:
            fr = grab_frames(host, nframes + 3)
        except Exception as e:
            print("  !! 抓帧失败 %s: %s" % (label, e))
            continue
        fr = fr[3:]                      # 丢掉改参数瞬间的在途帧
        if len(fr) < 4:
            print("  !! 帧数不足 %s (%d)" % (label, len(fr)))
            continue
        m = metrics(fr, ref)
        if ref is None:                  # 第一例(全关)作为位移参考
            ref = np.mean([cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.float32) for f in fr], axis=0)
        m["case"] = label
        m["note"] = note
        m["n"] = len(fr)
        rows.append(m)
        print("  %-22s lum=%6.1f flick=%5.2f tnoise=%5.2f p99=%5.1f lapvar=%8.1f "
              "R-G=%+6.2f B-G=%+6.2f clip=%5.1f%% rng=%5.1f d=(%+.1f,%+.1f) ncc=%.3f"
              % (label, m["mean_lum"], m["flicker"], m["tnoise"], m["tnoise_p99"],
                 m["lapvar"], m["r_g"], m["b_g"], m["clip"], m["p1_99"],
                 m["dx"], m["dy"], m["ncc"]))

    # 收尾：全关
    try:
        p = dict(BASELINE)
        p.update({"wb_r_pct": 100, "wb_b_pct": 100})
        api(host, p)
    except Exception:
        pass
    return ver, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1:9012")
    ap.add_argument("--frames", type=int, default=16)
    ap.add_argument("--settle", type=float, default=0.4)
    ap.add_argument("--settle-he", type=float, default=2.0,
                    help="HE 的 LUT 是逐帧 IIR，需要更久才稳定")
    ap.add_argument("--out", default="")
    ap.add_argument("--only", default="", help="逗号分隔的用例前缀，如 A,B,N")
    ap.add_argument("--jpeg-ll", type=int, default=-1, help="1=无损SOF3 0=有损SOF0")
    ap.add_argument("--jpeg-q", type=int, default=-1, help="有损质量 1..100")
    a = ap.parse_args()

    enc = {}
    if a.jpeg_ll >= 0:
        enc["jpeg_ll"] = a.jpeg_ll
    if a.jpeg_q >= 0:
        enc["jpeg_q"] = a.jpeg_q
    if enc:
        try:
            api_params(a.host, enc)
            print("编码器 -> %s" % enc)
            time.sleep(0.8)
        except Exception as e:
            print("!! 设置编码器失败: %s" % e)

    ver, rows = run(a.host, a.frames, a.settle, a.settle_he, a.only or None)
    if a.out and rows:
        cols = ["case", "n", "mean_lum", "flicker", "tnoise", "tnoise_p99",
                "sstd", "lapvar", "r_g", "b_g", "rg_slope", "bg_slope",
                "clip", "p1_99", "dx", "dy", "ncc", "note"]
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(",".join(cols) + "\n")
            for m in rows:
                f.write(",".join(
                    (("%.3f" % m[c]) if isinstance(m[c], float) else str(m.get(c, "")))
                    for c in cols) + "\n")
        print("CSV -> %s" % a.out)


if __name__ == "__main__":
    main()
