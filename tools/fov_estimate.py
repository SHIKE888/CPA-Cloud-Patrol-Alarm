#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fov_estimate.py —— 估算/反推镜头的水平视场角（给 depth_fov 用）

点云要和视频同一比例尺，就必须知道**水平** FOV（`/api/params` 里的 `depth_fov`，
默认 60° 只是个估计）。这个工具把三条常见路子都做成一行命令：

  a) 知道镜头焦距（镜头/规格书上写的 mm）
       python3 fov_estimate.py --lens 6
  b) 量尺法：在 L 处量出画面左右边缘之间的实际宽度
       python3 fov_estimate.py --ruler 1180 --dist 1000
  c) 已知物体法：A4 纸(210mm) 在 0.8 m 处占 520 px（画面宽 1920）
       python3 fov_estimate.py --obj 210 --dist 800 --px 520
  d) 只有标称"对角 FOV"（很多镜头这么标）：换算成水平
       python3 fov_estimate.py --diag 90

传感器默认按 IMX415 全幅 3864×2192 @ 1.45 µm = 5.603 mm（本仓库
docs/IMX415_datasheet.txt 第 76/85 行）。用 3840 宽的 4K 裁剪时换
--sensor-w 5.568，差别 < 0.5%。
"""
from __future__ import print_function

import argparse
import math

SENSOR_W_MM = 3864 * 1.45e-3          # 5.603 mm
SENSOR_H_MM = 2192 * 1.45e-3          # 3.178 mm


def hfov_from_lens(f_mm, sensor_w_mm):
    """水平视场角(度) = 2*atan(传感器宽 / (2*镜头焦距))"""
    return 2.0 * math.degrees(math.atan(sensor_w_mm / (2.0 * f_mm)))


def hfov_from_ruler(width_mm, dist_mm):
    """量尺法：画面左右边缘在距离 L 处跨 W"""
    return 2.0 * math.degrees(math.atan((width_mm * 0.5) / dist_mm))


def hfov_from_object(obj_mm, dist_mm, px, img_w):
    """已知物体法：物体宽 W 在距离 L 处占 p 像素（画面宽 img_w）"""
    f_px = px * dist_mm / float(obj_mm)
    return 2.0 * math.degrees(math.atan(img_w * 0.5 / f_px)), f_px


def diag_to_hfov(diag_deg, sensor_w_mm, sensor_h_mm):
    """标称对角 FOV -> 水平 FOV（同一焦距、同一传感器）"""
    diag_mm = math.hypot(sensor_w_mm, sensor_h_mm)
    f_mm = (diag_mm * 0.5) / math.tan(math.radians(diag_deg) * 0.5)
    return hfov_from_lens(f_mm, sensor_w_mm), f_mm


def main():
    ap = argparse.ArgumentParser(description="估算水平 FOV（给 depth_fov 用）")
    ap.add_argument("--lens", type=float, help="镜头焦距(mm)，如 3.6 / 6 / 8")
    ap.add_argument("--ruler", type=float, help="画面左右边缘在 --dist 处的实宽(mm)")
    ap.add_argument("--obj", type=float, help="已知物体实宽(mm)，如 A4 纸 210")
    ap.add_argument("--px", type=float, help="该物体在画面里占的像素宽")
    ap.add_argument("--dist", type=float, default=1000.0, help="距离(mm)，默认 1000")
    ap.add_argument("--diag", type=float, help="镜头标称对角 FOV(度)")
    ap.add_argument("--img-w", type=float, default=1920.0, help="画面宽(px)，默认 1920")
    ap.add_argument("--sensor-w", type=float, default=SENSOR_W_MM,
                    help="传感器有效宽(mm)，默认 5.603(IMX415 全幅)")
    a = ap.parse_args()

    hfov = None
    f_px = None
    src = ""
    if a.lens:
        hfov = hfov_from_lens(a.lens, a.sensor_w)
        src = "镜头焦距 %.2f mm（等效 f_px@%d = %.0f）" % (
            a.lens, int(a.img_w), (a.img_w * 0.5) / math.tan(math.radians(hfov) * 0.5))
    elif a.ruler:
        hfov = hfov_from_ruler(a.ruler, a.dist)
        src = "量尺法：%.0f mm 处画面宽 %.0f mm" % (a.dist, a.ruler)
    elif a.obj and a.px:
        hfov, f_px = hfov_from_object(a.obj, a.dist, a.px, a.img_w)
        src = "已知物体法：%.0f mm 宽物体在 %.0f mm 处占 %.0f px" % (
            a.obj, a.dist, a.px)
    elif a.diag:
        hfov, f_mm = diag_to_hfov(a.diag, a.sensor_w, SENSOR_H_MM)
        src = "标称对角 FOV %.0f° -> 等效焦距 %.2f mm" % (a.diag, f_mm)
    else:
        ap.print_help()
        return 2

    f_px_hd = (1920 * 0.5) / math.tan(math.radians(hfov) * 0.5)
    print("%s" % src)
    print("水平 FOV          : %.1f°" % hfov)
    print("垂直 FOV(16:9 画面): %.1f°"
          % (2.0 * math.degrees(math.atan(
              math.tan(math.radians(hfov) * 0.5) * 9.0 / 16.0))))
    print("等效焦距 @1920 宽 : %.0f px   @3840 宽 : %.0f px"
          % (f_px_hd, (3840 * 0.5) / math.tan(math.radians(hfov) * 0.5)))
    if f_px:
        print("（由物体法直接测到 f = %.0f px @%d 宽）" % (f_px, int(a.img_w)))
    print()
    print("-> 网页右键点云框把 FOV 改成 %.0f；或写参数 depth_fov=%.1f" % (hfov, hfov))
    print("   curl -s -X POST -H 'Content-Type: application/json' \\")
    print("        -d '{\"depth_fov\": %.1f}' http://127.0.0.1:9012/api/params" % hfov)
    print("   标定之后就不用这个了：引擎直接用标定 fx 反算 FOV。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
