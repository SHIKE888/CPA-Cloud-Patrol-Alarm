#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stereo_calib_auto.py —— 自动挑姿态的双目标定采集（摆一摆就够）

和 stereo_calib_capture.py 的区别：不用敲键盘，也不按固定节拍瞎存。
它一直从 /stream 抓帧，只有当"棋盘在两半幅里同时检测到、且姿态和已存的
都不够像"时才落盘。用户只要拿着板子在镜头前来回摆 1~2 分钟。

    /opt/miniforge3/envs/mlk-ov/bin/python stereo_calib_auto.py \
        -o calib_pairs -n 18 -t 150 --cols 9 --rows 6

姿态差异用 4 个标量描述（够用且不依赖相机内参）：
    cx, cy      棋盘角点重心（归一化到半幅宽高）
    sp          平均格距（px）—— 近似代表距离
    rot         棋盘在图像里的旋转角（度）
任意两张的加权距离 > --min-diff 才认为"姿态不同"。

落盘内容：L_%03d.png / R_%03d.png（半幅原图）+ poses.json（每张的姿态摘要）。
"""
from __future__ import print_function

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

import cv2
import numpy as np

FLAG = cv2.CALIB_CB_EXHAUSTIVE | cv2.CALIB_CB_ACCURACY | cv2.CALIB_CB_NORMALIZE_IMAGE


def iter_jpeg(url, timeout=8.0):
    resp = urllib.request.urlopen(url, timeout=timeout)
    buf = b""
    while True:
        chunk = resp.read(65536)
        if not chunk:
            return
        buf += chunk
        while True:
            i = buf.find(b"\xff\xd8")
            if i < 0:
                buf = buf[-2:]
                break
            j = buf.find(b"\xff\xd9", i + 2)
            if j < 0:
                buf = buf[i:]
                break
            yield buf[i:j + 2]
            buf = buf[j + 2:]


def find_board(gray, cols, rows):
    ok, c = cv2.findChessboardCornersSB(gray, (cols, rows), FLAG)
    if not ok:
        ok, c = cv2.findChessboardCorners(
            gray, (cols, rows),
            cv2.CALIB_CB_ADAPTIVE_THRESH | cv2.CALIB_CB_NORMALIZE_IMAGE)
        if ok:
            c = cv2.cornerSubPix(
                gray, c, (11, 11), (-1, -1),
                (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 40, 0.001))
    if not ok or c is None:
        return None
    return c.reshape(-1, 2).astype(np.float32)


def pose_desc(c, cols, rows, w, h):
    g = c.reshape(rows, cols, 2)
    d = np.diff(g, axis=1).reshape(-1, 2)
    sp = float(np.median(np.linalg.norm(d, axis=1)))
    ang = float(np.degrees(np.arctan2(np.median(d[:, 1]), np.median(d[:, 0]))))
    if ang > 90.0:
        ang -= 180.0
    elif ang < -90.0:
        ang += 180.0
    return {
        "cx": float(c[:, 0].mean() / w * 2.0 - 1.0),
        "cy": float(c[:, 1].mean() / h * 2.0 - 1.0),
        "sp": sp,
        "rot": ang,
    }


def dist(a, b, sp0):
    # 位置按半幅归一化跨度 2.0 折成 0~1；格距按参考格距归一化
    dp = 0.5 * np.hypot(a["cx"] - b["cx"], a["cy"] - b["cy"])
    ds = abs(a["sp"] - b["sp"]) / max(sp0, 1e-6)
    dr = abs(a["rot"] - b["rot"]) / 45.0
    return float(dp * 2.2 + ds * 1.6 + dr * 1.0)


def main():
    ap = argparse.ArgumentParser(description="自动挑姿态的双目标定采集")
    ap.add_argument("-o", "--out", default="calib_pairs")
    ap.add_argument("--url", default="http://127.0.0.1:9012/stream")
    ap.add_argument("--cols", type=int, default=9, help="内角点列数")
    ap.add_argument("--rows", type=int, default=6, help="内角点行数")
    ap.add_argument("-n", "--num", type=int, default=18)
    ap.add_argument("-t", "--time", type=float, default=150.0,
                    help="最长采集秒数")
    ap.add_argument("--gap", type=float, default=1.0,
                    help="两次落盘最小间隔(秒)")
    ap.add_argument("--min-diff", type=float, default=0.10,
                    help="姿态差异阈值，越大越挑")
    ap.add_argument("--margin", type=int, default=18,
                    help="角点距画面边缘最少像素")
    ap.add_argument("--min-std", type=float, default=6.0)
    ap.add_argument("--still", type=float, default=1.2,
                    help="判静止：前后两帧角点最大位移(px) 要小于它")
    ap.add_argument("--still-disp", type=float, default=0.5,
                    help="判静止：前后两帧左右视差之差(px) 要小于它")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    meta = []
    pj = os.path.join(args.out, "poses.json")
    if os.path.exists(pj):
        try:
            with open(pj) as f:
                meta = json.load(f).get("shots", [])
            print("[续采] %s 已有 %d 对，接着往下编号"
                  % (args.out, len(meta)))
            meta = [q for q in meta if "sp" in q]
        except Exception:                                  # noqa: BLE001
            meta = []
    base = len(meta)
    t0 = time.time()
    last = 0.0
    n_det = 0
    n_skip_same = 0
    prev = None          # (cl, cr, t) 上一帧检测结果，用来判静止
    n_moving = 0

    print("== 自动采集：请拿着棋盘在镜头前摆 ==")
    print("   目标 %d 对 / 最长 %.0fs；格点 %dx%d"
          % (args.num, args.time, args.cols, args.rows))
    print("   ★ 每摆好一个姿势要【停住约 1 秒】再换下一个（两半幅不同时刻出帧，")
    print("     板子在动时视差是假的，脚本会一直等静止）")
    print("   姿势：远(约1.5m) / 中(1m) / 近(0.6m)，各含 正对、左右转、上下转、"
          "斜放、四角各一张")
    print()

    try:
        frames = iter_jpeg(args.url)
        while True:
            if time.time() - t0 > args.time:
                print("\n[到时] 停止采集")
                break
            try:
                raw = next(frames)
            except StopIteration:
                print("\n[推流中断]")
                break
            img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
            if img is None:
                continue
            h, w = img.shape[:2]
            hw = w // 2
            L, R = img[:, :hw], img[:, hw:]
            if L.std() < args.min_std or R.std() < args.min_std:
                continue
            gl = cv2.cvtColor(L, cv2.COLOR_BGR2GRAY)
            gr = cv2.cvtColor(R, cv2.COLOR_BGR2GRAY)
            cl = find_board(gl, args.cols, args.rows)
            cr = find_board(gr, args.cols, args.rows)
            if cl is None or cr is None:
                continue
            n_det += 1
            m = args.margin
            if (cl[:, 0].min() < m or cl[:, 1].min() < m
                    or cl[:, 0].max() > hw - m or cl[:, 1].max() > h - m
                    or cr[:, 0].min() < m or cr[:, 1].min() < m
                    or cr[:, 0].max() > hw - m or cr[:, 1].max() > h - m):
                continue
            # —— 静止判定：两半幅不同时刻出帧，板子在动 => 视差全废 ——
            if prev is None or prev[0].shape != cl.shape:
                prev = (cl, cr, time.time())
                continue
            mv = max(float(np.abs(cl - prev[0]).max()),
                     float(np.abs(cr - prev[1]).max()))
            d_now = float(np.median(cl[:, 0] - cr[:, 0]))
            d_old = float(np.median(prev[0][:, 0] - prev[1][:, 0]))
            prev = (cl, cr, time.time())
            if mv > args.still or abs(d_now - d_old) > args.still_disp:
                n_moving += 1
                if n_moving % 8 == 1:
                    print("\r  [等静止] 位移 %.2fpx 视差跳动 %.2fpx  —  摆好姿势就别动了"
                          % (mv, abs(d_now - d_old)), end="")
                    sys.stdout.flush()
                continue
            n_moving = 0
            p = pose_desc(cl, args.cols, args.rows, hw, h)
            if time.time() - last < args.gap:
                continue
            sp0 = float(np.median([q["sp"] for q in meta])) if meta else p["sp"]
            if meta and min(dist(p, q, sp0) for q in meta) < args.min_diff:
                n_skip_same += 1
                continue
            idx = base + len(meta) + 1
            lp = os.path.join(args.out, "L_%03d.png" % idx)
            rp = os.path.join(args.out, "R_%03d.png" % idx)
            if not (cv2.imwrite(lp, L) and cv2.imwrite(rp, R)):
                continue
            p["idx"] = idx
            p["t"] = round(time.time() - t0, 2)
            p["z_est_mm"] = round(1450.0 * 20.0 / max(p["sp"], 1e-6), 1)
            meta.append(p)
            last = time.time()
            print("  [%2d/%d] 格距 %5.1fpx 位(%+.2f,%+.2f) 转角 %+5.1f°  约 %4.0f mm"
                  % (len(meta) + base, base + args.num, p["sp"], p["cx"], p["cy"],
                     p["rot"], p["z_est_mm"]))
            sys.stdout.flush()
            if len(meta) >= args.num:
                print("\n[够了] 采满 %d 对" % (len(meta) + base))
                break
    except KeyboardInterrupt:
        print("\n[中断]")
    except urllib.error.URLError as e:
        print("\n[错误] 连不上推流: %s" % e, file=sys.stderr)
        return 2
    finally:
        try:
            frames.close()
        except Exception:                                  # noqa: BLE001
            pass

    with open(os.path.join(args.out, "poses.json"), "w") as f:
        json.dump({"cols": args.cols, "rows": args.rows, "shots": meta}, f,
                  indent=1)
    print("\n== 采到 %d 对（检测到棋盘帧 %d，姿态重复跳过 %d）-> %s =="
          % (len(meta), n_det, n_skip_same, os.path.abspath(args.out)))
    if len(meta) < 8:
        print("  [!] 少于 8 对，标定会很飘；建议再摆一会儿", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
