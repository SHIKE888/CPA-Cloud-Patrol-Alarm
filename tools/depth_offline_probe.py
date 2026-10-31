#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""depth_offline_probe.py —— 用一张双目拼接快照离线检查"能不能匹配"

网页上的点云只有 1500 个点、还叠了取景，看不清算法本身好不好。
这个脚本直接拿 /snapshot.jpg(3840x1080) 拆成左右两目, 在 512 宽上跑一遍
SGBM, 打印:

  * 左右两目的亮度均值(差太多匹配会崩)
  * 有效视差占比 / 视差分位数 —— 只有"中位视差"落在一个合理区间才算匹配上
  * 正序(L,R) 与 反序(R,L) 分别算一遍 —— 反序如果反而更好, 说明左右目
    接反了(视差变负数, SGBM 找不到任何匹配)
  * 伪彩色视差图存到 /tmp/depth_probe_*.png, scp 回来看

用法(在板上跑):
    /opt/miniforge3/envs/mlk-ov/bin/python depth_offline_probe.py --url http://127.0.0.1:9012
"""
from __future__ import print_function

import argparse
import sys
import urllib.request

import cv2
import numpy as np


def fetch_snapshot(url):
    raw = urllib.request.urlopen(url + "/snapshot.jpg", timeout=10).read()
    a = np.frombuffer(raw, np.uint8)
    img = cv2.imdecode(a, cv2.IMREAD_COLOR)
    if img is None:
        raise SystemExit("快照解码失败")
    return img


def sgbm(gl, gr, nd=128, bs=5):
    m = cv2.StereoSGBM_create(
        0, nd, bs, 8 * bs * bs, 32 * bs * bs,
        disp12MaxDiff=1, uniquenessRatio=8,
        speckleWindowSize=60, speckleRange=2, preFilterCap=31,
        mode=cv2.STEREO_SGBM_MODE_SGBM_3WAY)
    return m.compute(gl, gr).astype(np.float32) / 16.0


def bm(gl, gr, nd=128, bs=15):
    m = cv2.StereoBM_create(nd, bs)
    m.setMinDisparity(0)
    return m.compute(gl, gr).astype(np.float32) / 16.0


def report(tag, gl, gr, disp):
    v = disp[disp > 0.5]
    tot = float(disp.size)
    if v.size < 50:
        print("  %-10s 有效 0.0%%  —— 完全没有匹配" % tag)
        return
    p = np.percentile(v, [5, 25, 50, 75, 95])
    print("  %-10s 有效 %5.1f%%  视差 p5/p25/p50/p75/p95 = "
          "%5.1f %5.1f %5.1f %5.1f %5.1f px"
          % (tag, 100.0 * v.size / tot, p[0], p[1], p[2], p[3], p[4]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:9012")
    ap.add_argument("--proc-w", type=int, default=512)
    ap.add_argument("--save", default="/tmp/depth_probe")
    a = ap.parse_args()

    img = fetch_snapshot(a.url)
    h, w = img.shape[:2]
    if w < 2 * h:                      # 不是双目拼接
        raise SystemExit("快照不是双目拼接(%dx%d)，请先把推流切到双目" % (w, h))
    hw = w // 2
    L = img[:, :hw]
    R = img[:, hw:]

    pw = a.proc_w
    ph = int(round(h * pw / float(hw))) & ~1
    sl = cv2.resize(L, (pw, ph), interpolation=cv2.INTER_LINEAR)
    sr = cv2.resize(R, (pw, ph), interpolation=cv2.INTER_LINEAR)
    gl = cv2.cvtColor(sl, cv2.COLOR_BGR2GRAY)
    gr = cv2.cvtColor(sr, cv2.COLOR_BGR2GRAY)

    print("快照 %dx%d -> 每目 %dx%d -> 处理 %dx%d" % (w, h, hw, h, pw, ph))
    print("亮度均值  左 %.1f   右 %.1f   差 %.1f"
          % (gl.mean(), gr.mean(), abs(float(gl.mean()) - float(gr.mean()))))

    for tag, g1, g2 in (("L-R", gl, gr), ("R-L(反序)", gr, gl)):
        print("SGBM:")
        report(tag, g1, g2, sgbm(g1, g2))
    print("BM(参考):")
    report("L-R", gl, gr, bm(gl, gr))

    # 伪彩色视差图(正序), 便于肉眼判断是不是整幅都在乱跳
    d = sgbm(gl, gr)
    dn = np.clip(d / 128.0, 0, 1)
    cm = cv2.applyColorMap((dn * 255).astype(np.uint8), cv2.COLORMAP_TURBO)
    cv2.imwrite(a.save + "_disp.png", cm)
    cv2.imwrite(a.save + "_left.png", sl)
    cv2.imwrite(a.save + "_right.png", sr)
    print("已存: %s_disp.png / _left.png / _right.png" % a.save)


if __name__ == "__main__":
    sys.exit(main())
