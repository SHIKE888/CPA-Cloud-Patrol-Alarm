#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
board_probe_tint.py —— 判定"单色算子偏色"的来源：常数偏移 / 亮度相关 / 特定亮度台阶

方法：静止场景连抓 N 帧取平均 -> 按 G(亮度) 分桶，看每桶的 mean(R-G)、mean(B-G)。
  · 各桶都差不多      -> 常数偏移（DC）
  · 随 G 单调变大      -> 亮度比例（增益/范围不匹配）
  · 只在某几个桶异常   -> 定点系数/裁剪 bug（如负色度被夹到 0）

用法：
  /opt/miniforge3/envs/mlk-ov/bin/python board_probe_tint.py --case 灰度
"""
import argparse
import json
import time
import urllib.request

import numpy as np
import cv2

sys_argv = None

BASE = {"PP_EN": 0, "ADV_MODE": 0, "ADV_SOBEL_SH": 8,
        "BASIC_EN": 0, "BASIC_GRAY": 0, "BASIC_GAUSS": 8, "BASIC_KER": 1,
        "BASIC_HE": 255, "BASIC_HE_CLIP": 255, "BASIC_CONTRAST": 4}

CASES = {
    "原图":   {},
    "灰度":   {"BASIC_EN": 1},
    "中值":   {"PP_EN": 1, "ADV_MODE": 4},
    "阈值":   {"PP_EN": 1, "ADV_MODE": 2, "ADV_THRESH": 128},
    "Sobel8": {"PP_EN": 1, "ADV_MODE": 1, "ADV_SOBEL_SH": 8},
    "Sobel4": {"PP_EN": 1, "ADV_MODE": 1, "ADV_SOBEL_SH": 4},
}


def api(host, payload):
    req = urllib.request.Request("http://%s/api/fpga" % host,
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def grab(host, n, timeout=20.0):
    r = urllib.request.urlopen(urllib.request.Request(
        "http://%s/stream" % host, headers={"User-Agent": "probe"}), timeout=timeout)
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


def report(name, frames):
    h = min(f.shape[0] for f in frames)
    w = min(f.shape[1] for f in frames)
    a = np.mean([f[:h, :w] for f in frames], axis=0)      # BGR float
    B, G, R = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    rg, bg = R - G, B - G
    g = G.ravel()
    print("\n==== %s ====  pixels=%d" % (name, g.size))
    print("  通道均值  R=%.2f G=%.2f B=%.2f   |  范围 R[%d..%d] G[%d..%d] B[%d..%d]"
          % (R.mean(), G.mean(), B.mean(),
             R.min(), R.max(), G.min(), G.max(), B.min(), B.max()))
    print("  mean(R-G)=%+.3f  mean(B-G)=%+.3f  max|R-G|=%.0f max|B-G|=%.0f"
          % (rg.mean(), bg.mean(), np.abs(rg).max(), np.abs(bg).max()))
    print("  亮度分桶（左=G 区间，右=该区间内 R-G / B-G / 像素数）")
    edges = np.linspace(0, 256, 17).astype(int)
    rgf, bgf, gf = rg.ravel(), bg.ravel(), g
    for i in range(16):
        lo, hi = edges[i], edges[i + 1]
        m = (gf >= lo) & (gf < hi)
        cnt = int(m.sum())
        if cnt < 50:
            print("    [%3d,%3d)  n=%8d   -" % (lo, hi, cnt))
            continue
        print("    [%3d,%3d)  n=%8d   R-G=%+7.3f  B-G=%+7.3f" %
              (lo, hi, cnt, rgf[m].mean(), bgf[m].mean()))
    # 色度可分离性：R,G,B 三通道做 PCA，看第一主成分解释率
    X = np.stack([R.ravel(), G.ravel(), B.ravel()], 1).astype(np.float64)
    X -= X.mean(0)
    cov = np.cov(X, rowvar=False)
    ev = np.linalg.eigvalsh(cov)[::-1]
    print("  通道协方差特征值 %.1f / %.2f / %.2f  -> 第一主成分占 %.4f"
          % (ev[0], ev[1], ev[2], ev[0] / max(1e-9, ev.sum())))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1:9012")
    ap.add_argument("--frames", type=int, default=10)
    ap.add_argument("--case", default="")
    a = ap.parse_args()
    names = [a.case] if a.case else list(CASES)
    for nm in names:
        if nm not in CASES:
            print("未知用例 %s（可选 %s）" % (nm, "/".join(CASES)))
            continue
        p = dict(BASE)
        p.update({"wb_r_pct": 100, "wb_b_pct": 100})
        try:
            api(a.host, p)
            time.sleep(0.4)
            api(a.host, CASES[nm]) if CASES[nm] else None
            time.sleep(1.0)
            fr = grab(a.host, a.frames + 3)[3:]
        except Exception as e:
            print("!! %s 失败: %s" % (nm, e))
            continue
        if len(fr) < 3:
            print("!! %s 帧数不足" % nm)
            continue
        report(nm, fr)
    p = dict(BASE)
    p.update({"wb_r_pct": 100, "wb_b_pct": 100})
    try:
        api(a.host, p)
    except Exception:
        pass


if __name__ == "__main__":
    main()
