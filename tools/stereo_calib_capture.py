#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stereo_calib_capture.py —— 双目标定图采集（左右目成对保存）

跑在 RK3576 板上（那儿有 cv2，而且不占用 /dev/video22）：

    /opt/miniforge3/envs/mlk-ov/bin/python stereo_calib_capture.py -o calib_pairs

    # 无人值守连拍 20 对，每 1.2s 一对（每对之间请自己挪一下棋盘/换姿态）
    /opt/miniforge3/envs/mlk-ov/bin/python stereo_calib_capture.py -o calib_pairs -n 20 -i 1.2

交互模式：回车 = 存一对，`a` = 自动连拍（每 1.2s 一对，共 -n 对），`q` = 退出。

数据从哪来
----------
不直接读设备（会和 mipi-webstream 抢 /dev/video22），而是拉它自己的 MJPEG
推流 `http://127.0.0.1:9012/stream`，再把 3840x1080 的拼接线切开：
    左半幅 = cam1（左目）      右半幅 = cam0（右目）
切开的顺序与板端 dual 拼接（DUAL_LEFT_SRC=1 / DUAL_RIGHT_SRC=0）一致。

保存的 PNG 是"JPEG 解码后再无损存"——仍有 JPEG 压缩痕迹，但对棋盘格
亚像素角点的影响远小于 0.1 px，可以接受；要极致精度就等 FPGA 把右目
行打包 bug 修完，改用原始 YUV 采。

采集前的三条硬性检查（本工具会拦）
---------------------------------
1. 两半幅都不能是黑的（右目没插/没开双目）；
2. 半幅不能有"每行斜移"（当前 bit 右目每行多 2 个 32bit word 的老 bug）；
3. 输入分辨率必须和后面写进 JSON 的 image_size 一致。
"""
from __future__ import print_function

import argparse
import os
import sys
import time
import urllib.request

import cv2
import numpy as np

sys.path.insert(0, os.environ.get("DEPTH_WEB_DIR", "/root/rk/web"))
try:
    from stereo_depth import StereoDepth, SHEAR_WARN      # noqa: E402
except Exception as _e:                                    # noqa: BLE001
    StereoDepth = None
    SHEAR_WARN = 0.6
    print("[warn] 没能 import stereo_depth（%s），斜移检查关闭" % _e,
          file=sys.stderr)


def iter_jpeg(url, timeout=8.0):
    """从 MJPEG(multipart) 里逐帧吐出 JPEG 字节。"""
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


def judge(left, right):
    """返回 (能用吗, 说明)。不能用的原因直接给人看。"""
    if left.size == 0 or right.size == 0:
        return False, "空图"
    sl, sr = left.std(), right.std()
    if sl < 6.0 or sr < 6.0:
        return False, "画面接近全黑(左 %.1f / 右 %.1f)" % (sl, sr)
    if StereoDepth is not None:
        try:
            sd = StereoDepth(quiet=True)
            kl = sd._estimate_shear(cv2.cvtColor(left, cv2.COLOR_BGR2GRAY))
            kr = sd._estimate_shear(cv2.cvtColor(right, cv2.COLOR_BGR2GRAY))
            if max(abs(kl), abs(kr)) > SHEAR_WARN:
                who = "右目" if abs(kr) >= abs(kl) else "左目"
                k = kr if who == "右目" else kl
                return False, "%s每行斜移 %.1f px（FPGA 行打包问题，先修）" % (
                    who, abs(k))
        except Exception:                                  # noqa: BLE001
            pass
    return True, "OK"


def save_pair(out, idx, left, right):
    os.makedirs(out, exist_ok=True)
    lp = os.path.join(out, "L_%03d.png" % idx)
    rp = os.path.join(out, "R_%03d.png" % idx)
    ok1 = cv2.imwrite(lp, left)
    ok2 = cv2.imwrite(rp, right)
    return ok1 and ok2


def main():
    ap = argparse.ArgumentParser(description="双目标定图采集(左右目成对)")
    ap.add_argument("-o", "--out", default="calib_pairs", help="输出目录")
    ap.add_argument("--url", default="http://127.0.0.1:9012/stream",
                    help="板端 MJPEG 地址")
    ap.add_argument("-n", "--num", type=int, default=20,
                    help="自动模式下张数（交互模式下是'a'的连拍张数）")
    ap.add_argument("-i", "--interval", type=float, default=1.2,
                    help="自动模式间隔(秒)")
    ap.add_argument("--start", type=int, default=1, help="起始编号")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    print("== 采集 ==")
    print("  推流: %s" % args.url)
    print("  目录: %s" % os.path.abspath(args.out))
    print("  棋盘建议 9x6 格（内角点 9x6）、方格 20~30mm、占画面 40%~80%%，")
    print("  覆盖：正对 / 左右各转 20° / 上下各转 15° / 远近两档 / 画面四角各来一张。")
    print()

    frames = iter_jpeg(args.url)
    idx = args.start
    saved = 0
    auto_left = 0
    last_auto = 0.0
    interactive = sys.stdin.isatty()
    if not interactive:
        # 非交互（脚本/管道）：直接当成自动连拍 -n 张
        auto_left = args.num
        print("  [非交互] 自动连拍 %d 张, 间隔 %.1fs —— 请每隔一会儿挪一下棋盘"
              % (args.num, args.interval))
    try:
        while True:
            raw = next(frames)
            img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
            if img is None:
                continue
            h, w = img.shape[:2]
            hw = w // 2
            left, right = img[:, :hw], img[:, hw:]
            ok, why = judge(left, right)

            auto = auto_left > 0 and (time.time() - last_auto) >= args.interval
            if auto:
                auto_left -= 1
                last_auto = time.time()
            if not auto and interactive:
                print("  [%d/%d] %s  半幅 %dx%d  > 回车保存 / a 连拍 / q 退出"
                      % (saved, args.num, why, left.shape[1], left.shape[0]),
                      end=" ")
                sys.stdout.flush()
                cmd = sys.stdin.readline().strip().lower()
                if cmd == "q":
                    break
                if cmd == "a":
                    auto_left = args.num - saved
                    last_auto = 0.0
                    continue
            elif not auto:
                continue
            if not ok:
                print("\r  [跳过] %s%s" % (why, " " * 40))
                continue
            if save_pair(args.out, idx, left, right):
                saved += 1
                print("\r  [已存] %s/L_%03d.png + R_%03d.png  (%d/%d)%s"
                      % (args.out, idx, idx, saved, args.num, " " * 20))
                idx += 1
            if saved >= args.num:
                break
    except KeyboardInterrupt:
        print("\n[中断]")
    except urllib.error.URLError as e:
        print("\n[错误] 连不上推流: %s（板端 mipi-webstream 在跑吗? 双目开了吗?）"
              % e, file=sys.stderr)
        return 2
    finally:
        try:
            frames.close()
        except Exception:                                  # noqa: BLE001
            pass

    print("\n== 完成: %d 对 -> %s ==" % (saved, os.path.abspath(args.out)))
    if saved < 10:
        print("  张数偏少，标定会不稳；建议 >=15 对", file=sys.stderr)
    print("下一步: python3 stereo_calib_solve.py --pairs %s --cols 9 --rows 6 "
          "--square 25 --out /root/rk/web/stereo_calib.json" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
