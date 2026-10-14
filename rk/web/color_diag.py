#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""color_diag.py —— YUV 颜色诊断

判断 FPGA 送来的 YUV422 到底应该按哪种方式解释:
   U/V 顺序   : 正常 / 交换
   色彩矩阵   : BT.601 / BT.709
   量程       : limited(16-235) / full(0-255)

用法(先停掉占用设备的 mipi_webstream):
    pkill -f mipi_webstream
    /opt/miniforge3/envs/mlk-ov/bin/python color_diag.py [/dev/video22]

输出:
    /tmp/diag_montage.jpg   所有组合的对比图(横排缩小)
    /tmp/diag_*.jpg         每个组合单独一张
    终端打印各组合的统计(Y/Cb/Cr 均值)
"""
import os
import subprocess
import sys

import numpy as np
import cv2

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/video22"
W, H = 1920, 1080
RAW = "/tmp/_diag.raw"


def grab(fmt):
    if os.path.exists(RAW):
        os.remove(RAW)
    cmd = ["v4l2-ctl", "-d", DEV,
           "--set-fmt-video=width=%d,height=%d,pixelformat=%s" % (W, H, fmt),
           "--stream-mmap", "--stream-count=1", "--stream-to=" + RAW]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(RAW):
        return None, (r.stderr or r.stdout or "unknown").strip()
    return np.fromfile(RAW, dtype=np.uint8), None


def split_nv16(buf):
    """YUV422: Y 平面 + 交织 CbCr 平面 (每行 W/2 对)"""
    y = buf[:W * H].reshape(H, W)
    c = buf[W * H:W * H + W * H].reshape(H, W // 2, 2)
    cb = np.repeat(c[:, :, 0], 2, axis=1)
    cr = np.repeat(c[:, :, 1], 2, axis=1)
    return y, cb, cr


def split_nv12(buf):
    """YUV420: Y 平面 + (H/2, W/2) 交织 CbCr"""
    y = buf[:W * H].reshape(H, W)
    c = buf[W * H:W * H + W * H // 2].reshape(H // 2, W // 2, 2)
    cb = np.repeat(np.repeat(c[:, :, 0], 2, 0), 2, 1)
    cr = np.repeat(np.repeat(c[:, :, 1], 2, 0), 2, 1)
    return y, cb, cr


def yuv2bgr(y, cb, cr, mat, full):
    yf = y.astype(np.float32)
    if not full:
        yf = (yf - 16.0) * (255.0 / 219.0)
    u = cb.astype(np.float32) - 128.0
    v = cr.astype(np.float32) - 128.0
    if mat == "601":
        kr, kg_u, kg_v, kb = 1.402, -0.344136, -0.714136, 1.772
    else:
        kr, kg_u, kg_v, kb = 1.5748, -0.1873, -0.4681, 1.8556
    r = yf + kr * v
    g = yf + kg_u * u + kg_v * v
    b = yf + kb * u
    return np.clip(np.dstack([b, g, r]), 0, 255).astype(np.uint8)


def stats(y, cb, cr):
    return ("Y mean=%6.1f min=%3d max=%3d | Cb mean=%6.1f | Cr mean=%6.1f"
            % (y.mean(), y.min(), y.max(), cb.mean(), cr.mean()))


def probe_cv_raw():
    """探测能否让 OpenCV 交回原始 YUV 缓冲 (绕过它自带的 full-range 601 转换)"""
    print("\n=== OpenCV 原始缓冲探测 (CAP_PROP_CONVERT_RGB=0) ===")
    for fourcc in ("NV16", "NV12"):
        cap = cv2.VideoCapture(DEV, cv2.CAP_V4L2)
        if not cap.isOpened():
            print("  打不开 %s" % DEV)
            return
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, W)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
        r = cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
        ok, f = cap.read()
        if f is None:
            print("  %s: set(CONVERT_RGB,0)=%s read=%s shape=None" % (fourcc, r, ok))
        else:
            print("  %s: set(CONVERT_RGB,0)=%s read=%s shape=%s dtype=%s"
                  % (fourcc, r, ok, f.shape, f.dtype))
        cap.release()


def main():
    print("设备: %s   %dx%d" % (DEV, W, H))

    probe_cv_raw()

    buf, err = grab("NV16")
    src = "NV16 (YUV422, 保留全彩度)"
    if err:
        print("NV16 抓取失败: %s" % err)
        buf, err = grab("NV12")
        src = "NV12 (YUV420)"
        if err:
            print("NV12 抓取失败: %s" % err)
            return 1

    print("使用格式: %s (%d 字节)" % (src, len(buf)))
    y, cb, cr = split_nv16(buf) if src.startswith("NV16") else split_nv12(buf)

    print("\n=== 原始 Y/Cb/Cr 统计 ===")
    print("  " + stats(y, cb, cr))
    print("  说明: 中性场景下 Cb 与 Cr 均值应接近; 差值大 = 有明显色偏")
    print("  原始 Cb-Cr = %.1f ; 交换后 Cb-Cr = %.1f"
          % (cb.mean() - cr.mean(), cr.mean() - cb.mean()))

    variants = []
    for uv_name, (a, b) in (("UV正常", (cb, cr)), ("UV交换", (cr, cb))):
        for mat in ("601", "709"):
            for full in (False, True):
                rng = "full" if full else "limited"
                img = yuv2bgr(y, a, b, mat, full)
                name = "%s_%s_%s" % (uv_name.replace("UV", "uv"), mat, rng)
                cv2.imwrite("/tmp/diag_%s.jpg" % name, img)
                m = img.reshape(-1, 3).mean(0)
                variants.append((name, img))
                print("  %-20s BGR均值 = %s" % (name, np.round(m, 1)))

    # 拼成 2x4 的对比图
    scale_w = 640
    scale_h = int(H * scale_w / W)
    tiles = []
    for name, img in variants:
        t = cv2.resize(img, (scale_w, scale_h), interpolation=cv2.INTER_AREA)
        cv2.rectangle(t, (0, 0), (scale_w - 1, 34), (0, 0, 0), -1)
        cv2.putText(t, name, (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                    (255, 255, 255), 2, cv2.LINE_AA)
        tiles.append(t)
    rows = [np.hstack(tiles[i:i + 2]) for i in range(0, len(tiles), 2)]
    montage = np.vstack(rows)
    cv2.imwrite("/tmp/diag_montage.jpg", montage)
    print("\n对比图: /tmp/diag_montage.jpg")
    return 0


if __name__ == "__main__":
    sys.exit(main())
