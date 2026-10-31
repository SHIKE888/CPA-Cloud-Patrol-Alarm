#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stereo_calib_solve.py —— 双目标定解算：棋盘格图对 -> stereo_calib.json

用法（板上或 PC 都行，只要装了 opencv-python）：

    # 1) 正常解算（9x6 内角点、方格 25 mm）
    python3 stereo_calib_solve.py --pairs calib_pairs --cols 9 --rows 6 \
            --square 25 --out /root/rk/web/stereo_calib.json

    # 2) 联合精修（相信检测精度时用；张数少时反而更抖）
    python3 stereo_calib_solve.py ... --refine

    # 3) 不连板也能自证：合成一对"已知 f=800, B=45mm"的图对跑完整流程
    python3 stereo_calib_solve.py --selftest

--square 单位是**毫米**；写进 JSON 的基线是米。程序内部全用毫米算，
最后 /1000，避免混单位（这是标定最常见的翻车点）。

产物 stereo_calib.json 的消费方是 rk/web/stereo_depth.py：
  * 有它 -> 用标定的 fx/cx/cy + 基线，并先做极线校正再匹配；
  * 没有它 -> 退回 FOV 估算。文件按 mtime 热加载，改完不用重启服务。
"""
from __future__ import print_function

import argparse
import glob
import json
import os
import sys
import tempfile
import time

import cv2
import numpy as np

SUB_CRIT = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.01)


# --------------------------------------------------------------------- 角点
def find_board(gray, pattern):
    """返回 (ok, corners[N,1,2])。SB 版自带亚像素，失败再走经典版+refine。"""
    try:
        ok, c = cv2.findChessboardCornersSB(
            gray, pattern, flags=cv2.CALIB_CB_EXHAUSTIVE | cv2.CALIB_CB_ACCURACY)
        if ok and c is not None:
            return True, np.asarray(c, np.float32).reshape(-1, 1, 2)
    except Exception:                                      # noqa: BLE001
        pass
    ok, c = cv2.findChessboardCorners(
        gray, pattern,
        flags=cv2.CALIB_CB_ADAPTIVE_THRESH | cv2.CALIB_CB_NORMALIZE_IMAGE)
    if not ok or c is None:
        return False, None
    c = cv2.cornerSubPix(gray, c, (5, 5), (-1, -1), SUB_CRIT)
    return True, c.reshape(-1, 1, 2)


def obj_grid(cols, rows, square_mm):
    """内角点 objp（板面 z=0，单位 mm，中心在原点）。"""
    p = np.zeros((cols * rows, 3), np.float32)
    p[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)
    p[:, 0] = (p[:, 0] - (cols - 1) / 2.0) * square_mm
    p[:, 1] = (p[:, 1] - (rows - 1) / 2.0) * square_mm
    return p


# --------------------------------------------------------------------- 解算
def solve(pairs, cols, rows, square_mm, refine=False):
    lp = sorted(glob.glob(os.path.join(pairs, "L_*.png")))
    if not lp:
        raise SystemExit("在 %s 下没找到 L_*.png" % pairs)
    pattern = (cols, rows)
    objp = obj_grid(cols, rows, square_mm)
    op, ip1, ip2, size, used, skipped = [], [], [], None, [], []
    for f in lp:
        rf = os.path.join(pairs, os.path.basename(f).replace("L_", "R_", 1))
        if not os.path.exists(rf):
            skipped.append((os.path.basename(f), "缺 R 图"))
            continue
        g1 = cv2.imread(f, cv2.IMREAD_GRAYSCALE)
        g2 = cv2.imread(rf, cv2.IMREAD_GRAYSCALE)
        if g1 is None or g2 is None:
            skipped.append((os.path.basename(f), "读不到"))
            continue
        if size is None:
            size = (g1.shape[1], g1.shape[0])
        elif (g1.shape[1], g1.shape[0]) != size:
            skipped.append((os.path.basename(f), "尺寸不一致"))
            continue
        ok1, c1 = find_board(g1, pattern)
        ok2, c2 = find_board(g2, pattern)
        if not (ok1 and ok2):
            skipped.append((os.path.basename(f), "左%s 右%s 角点未找到"
                            % ("√" if ok1 else "×", "√" if ok2 else "×")))
            continue
        op.append(objp)
        ip1.append(c1)
        ip2.append(c2)
        used.append(os.path.basename(f))
    if len(op) < 3:
        raise SystemExit("有效图对只有 %d 张（至少 3 张, 建议 >=15）。被跳过: %s"
                         % (len(op), skipped))
    print("== 参与解算 %d 对 ==" % len(op))
    for k, v in skipped:
        print("   跳过 %-16s %s" % (k, v))

    r1, K1, D1, _rv1, _tv1 = cv2.calibrateCamera(op, ip1, size, None, None)
    r2, K2, D2, _rv2, _tv2 = cv2.calibrateCamera(op, ip2, size, None, None)
    flags = 0 if refine else cv2.CALIB_FIX_INTRINSIC
    rms, K1, D1, K2, D2, R, T, E, F = cv2.stereoCalibrate(
        op, ip1, ip2, K1, D1, K2, D2, size,
        flags=flags, criteria=SUB_CRIT)
    T = np.asarray(T, np.float64).reshape(3, 1)
    baseline_m = float(np.linalg.norm(T)) / 1000.0        # mm -> m
    R1, R2, P1, P2, Q, roi1, roi2 = cv2.stereoRectify(
        K1, D1, K2, D2, size, R, T, flags=cv2.CALIB_ZERO_DISPARITY, alpha=0)

    out = {
        "version": 1,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "image_size": [int(size[0]), int(size[1])],
        "board": {"cols": cols, "rows": rows, "square_mm": square_mm,
                  "pairs": len(op)},
        "left": {"K": K1.tolist(), "D": D1.ravel().tolist(), "rms": round(r1, 3)},
        "right": {"K": K2.tolist(), "D": D2.ravel().tolist(), "rms": round(r2, 3)},
        "stereo": {"R": R.tolist(), "T": T.ravel().tolist(),
                   "baseline_m": round(baseline_m, 6),
                   "rms": round(float(rms), 3),
                   "E": E.tolist(), "F": F.tolist()},
        "rect": {"R1": R1.tolist(), "R2": R2.tolist(), "P1": P1.tolist(),
                 "P2": P2.tolist(), "Q": Q.tolist()},
    }
    return out, dict(rms=float(rms), rms_l=r1, rms_r=r2, used=used)


def report(out, extra):
    K = out["left"]["K"]
    fx, fy = K[0][0], K[1][1]
    B = out["stereo"]["baseline_m"]
    print("\n== 结果 ==")
    print("  图像尺寸      : %d x %d" % tuple(out["image_size"]))
    print("  左目 fx/fy    : %.2f / %.2f px     主点 (%.2f, %.2f)"
          % (fx, fy, K[0][2], K[1][2]))
    print("  畸变(左)      : %s" % np.round(out["left"]["D"], 4).tolist())
    print("  基线 |T|      : %.2f mm  (T=%s mm)"
          % (B * 1000.0, np.round(np.array(out["stereo"]["T"]) * 1000.0, 2).tolist()))
    print("  单目 RMS      : 左 %.3f px  右 %.3f px"
          % (extra["rms_l"], extra["rms_r"]))
    print("  立体 RMS      : %.3f px" % extra["rms"])
    if abs(B * 1000.0 - 45.0) > 3.0:
        print("  ⚠ 基线 %.1f mm 与实测中心距 45 mm 差 >3 mm："
              "棋盘方格实际尺寸填错？" % (B * 1000.0))
    if extra["rms"] > 1.0:
        print("  ⚠ 立体 RMS > 1 px：图对质量不够（模糊/斜切/张数少），建议重采")
    print("\n  理论精度（1 像素视差的深度误差, z²/(f·B)）:")
    for z in (0.5, 1.0, 2.0, 3.0):
        print("    %4.1f m -> ±%.1f mm   (该距离视差 ≈ %.1f px)"
              % (z, (z * z / (fx * B)) * 1000.0, fx * B / z))


# --------------------------------------------------------------------- 自检
def _board_texture(cols, rows, sq_px):
    w, h = (cols + 1) * sq_px, (rows + 1) * sq_px
    img = np.full((h, w), 255, np.uint8)
    for i in range(cols + 1):
        for j in range(rows + 1):
            if (i + j) % 2 == 0:
                img[j * sq_px:(j + 1) * sq_px, i * sq_px:(i + 1) * sq_px] = 0
    return img


def _render(texture, sq_px, cols, rows, square_mm, K, rvec, tvec, size):
    """把棋盘纹理按“物点(mm) -> 像素”的单应投到空白图上。

    ⚠ 这里的物点必须用**真实尺寸(mm)**：解算阶段拿的是 mm，两边不同
      尺度会让解出来的基线按比例缩水（曾经踩过：40px/格 纹理 + 25mm 解算
      -> 基线 45mm 变 28.1mm，正是 25/40）。
    """
    src = (obj_grid(cols, rows, 1.0)[:, :2] * sq_px
           + np.array([sq_px, sq_px])).astype(np.float32)
    dst, _ = cv2.projectPoints(obj_grid(cols, rows, square_mm),
                               rvec, tvec, K, None)
    H, _s = cv2.findHomography(src, dst.reshape(-1, 2))
    return cv2.warpPerspective(texture, H, size, flags=cv2.INTER_LINEAR,
                               borderValue=255)


def selftest(n=12):
    """合成已知参数的图对，跑完整流程，检查 f / B 是否解得回来。"""
    cols, rows, sq_mm, sq_px = 9, 6, 25.0, 40
    W, H = 1280, 720
    f_true, B_true = 800.0, 0.045
    K = np.array([[f_true, 0, W / 2.0], [0, f_true, H / 2.0], [0, 0, 1]],
                 np.float64)
    tex = _board_texture(cols, rows, sq_px)
    rng = np.random.RandomState(0)
    tmp = tempfile.mkdtemp(prefix="stereo_sel ")
    for i in range(n):
        rx = np.deg2rad(rng.uniform(-18, 18))
        ry = np.deg2rad(rng.uniform(-22, 22))
        rz = np.deg2rad(rng.uniform(-6, 6))
        rvec = np.array([rx, ry, rz], np.float64)
        tvec = np.array([rng.uniform(-45, 45), rng.uniform(-30, 30),
                         550 + rng.uniform(-90, 90)], np.float64)
        L = _render(tex, sq_px, cols, rows, sq_mm, K, rvec, tvec, (W, H))
        t_r = tvec + np.array([-B_true * 1000.0, 0, 0])   # 右目在左目 x 负方向
        Rimg = _render(tex, sq_px, cols, rows, sq_mm, K, rvec, t_r, (W, H))
        cv2.imwrite(os.path.join(tmp, "L_%03d.png" % (i + 1)), L)
        cv2.imwrite(os.path.join(tmp, "R_%03d.png" % (i + 1)), Rimg)
    print("== 自检: 合成 %d 对 (真值 f=%.0f px, B=%.1f mm) ==" % (n, f_true, B_true * 1e3))
    out, extra = solve(tmp, cols, rows, sq_mm, refine=False)
    report(out, extra)
    f_err = abs(out["left"]["K"][0][0] - f_true) / f_true * 100.0
    b_err = abs(out["stereo"]["baseline_m"] - B_true) / B_true * 100.0
    ok = f_err < 3.0 and b_err < 3.0
    print("\n  自检: f 误差 %.2f%%  基线误差 %.2f%%  => %s"
          % (f_err, b_err, "PASS" if ok else "FAIL"))
    return 0 if ok else 1


# --------------------------------------------------------------------- 入口
def main():
    ap = argparse.ArgumentParser(description="双目标定解算 -> stereo_calib.json")
    ap.add_argument("--pairs", default="calib_pairs", help="L_*.png / R_*.png 目录")
    ap.add_argument("--cols", type=int, default=9, help="棋盘内角点列数(横向格数-1)")
    ap.add_argument("--rows", type=int, default=6, help="棋盘内角点行数(纵向格数-1)")
    ap.add_argument("--square", type=float, default=25.0, help="方格边长(mm)")
    ap.add_argument("--out", default="stereo_calib.json", help="输出 JSON")
    ap.add_argument("--refine", action="store_true",
                    help="联合精修内参(张数多时更准, 张数少时更抖)")
    ap.add_argument("--selftest", action="store_true", help="合成图对自检")
    a = ap.parse_args()

    if a.selftest:
        return selftest()

    out, extra = solve(a.pairs, a.cols, a.rows, a.square, refine=a.refine)
    report(out, extra)
    d = os.path.dirname(os.path.abspath(a.out))
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1)
    print("\n  已写入 %s（stereo_depth.py 会按 mtime 自动重载, 不用重启服务）"
          % os.path.abspath(a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
