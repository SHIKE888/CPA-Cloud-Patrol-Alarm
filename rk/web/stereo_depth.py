#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stereo_depth.py —— 双目深度（轻量化稀疏点云，板端 CPU）

═══════════════════════════════════════════════════════════════════════════
  给一对已对齐的左右目 BGR 帧，输出一撮彩色 3D 点 + 一份质量报告。
  不画图、不编码、不碰网络 —— 只有 "喂帧 → 拿结果" 两个动作。

  为什么放在板端而不是浏览器
  --------------------------
  两路 1920x1080@30 的原始像素约 12 MB/帧。搬进浏览器做匹配，光是传数据就
  已经比整条 MJPEG 链路还重。板端算完只传 ~1500 个点 = 18 KB/帧（10Hz
  也才 180 KB/s），这才是"轻量化"。

  轻量化的四条措施
  ----------------
  1) 只在有人看的时候算：前端 10Hz 拉 /api/depth，WANT_TTL 秒没人拉 =>
     引擎直接丢弃新帧，采集/编码线程零额外开销（本模块的线程在睡觉）。
  2) 两级降采样：SGBM 只在 512 宽（自适应 384~640）上跑，点云再抽到 ~1500 点。
  3) 每点只打包 9 字节（xyz 各 int16 毫米 + RGB888），base64 进 JSON。
  4) 不做左右一致性检查 / WLS 精修：先把链路打通；精度靠后面的标定参数补。

  坐标系
  ------
  以【左目】光心为原点，x 向右、y 向下、z 向前，单位 m（打包时转毫米）。

  标定（优先级从高到低）
  ----------------------
  1) **`stereo_calib.json`**（与本文件同目录，或环境变量 `DEPTH_CALIB` 指定）：
     里面有左右目内参 K/D、立体外参 R/T、基线。存在时：
       - 先用 `stereoRectify` + `initUndistortRectifyMap` 把两目**极线校正**
         （畸变 + 行列对齐）后再匹配；
       - 反投影用标定的 fx/cx/cy，基线用标定的 |T|（通常≈45 mm）。
     文件按 mtime 热加载：改完不用重启服务。
  2) 没有标定文件时：焦距由水平视场角反算 f = (W/2)/tan(FOV/2)，FOV 取参数
     `depth_fov`（默认 60°，网页双击点云框可改）；基线取 `DEPTH_BASELINE_M`
     （默认 0.045 m）；主点假设在图像正中；不做畸变校正。

  标定怎么做：见 docs/STEREO_CALIB_TUTORIAL.md（采集 tools/stereo_calib_capture.py
  → 解算 tools/stereo_calib_solve.py → 落地本文件 → 用尺子验收）。

  已知的输入侧问题（2026-10-31 板上实测，见 docs/STEREO_DEPTH_2026-10-31.md）
  ------------------------------------------------------------------------
  当前 bitstream 的双目拼接里，**右半幅（cam0）每行多 2 个 32bit word**，
  整幅被拖成斜条纹：相邻行水平偏移实测 -4.00 px/row（左半幅 0.00）。
  这不是"整体斜移"，而是行内容被逐行滑窗取走（行尾多出的 word 把下一行的
  像素顶进来），所以**任何线性去斜都无法恢复**，只能 FPGA 侧修。
  本模块因此只"检测并报警"（shear_l / shear_r），不做任何图像补偿：
  在右目修好之前，点云质量会很低，前端会把原因直接写在画面上。

  自检（不连板也能验证公式与耗时）
  --------------------------------
      python3 stereo_depth.py --selftest
  用已知视差 32 px 的合成纹理对跑一遍，检查 z 的中位数是否等于 f*B/d
  （误差 < 3%），并打印每帧耗时。
═══════════════════════════════════════════════════════════════════════════
"""
from __future__ import print_function

import base64
import os
import sys
import threading
import time

import numpy as np

try:
    import cv2
except Exception as _e:                                     # pragma: no cover
    cv2 = None
    _CV2_ERR = "%s: %s" % (type(_e).__name__, _e)
else:
    _CV2_ERR = ""

# ------------------------------------------------------------------ 常量
BASELINE_M = float(os.environ.get("DEPTH_BASELINE_M", "0.045"))   # 45 mm
CALIB_PATH = os.environ.get(
    "DEPTH_CALIB",
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "stereo_calib.json"))
DEFAULT_FOV = 60.0          # 水平视场角(度) —— 未标定时的估算
PROC_W_DEF = 512            # SGBM 处理宽度
PROC_W_MIN, PROC_W_MAX = 384, 640
MAX_DISP = 128              # 视差搜索上限(必须是 16 的倍数)
TARGET_PTS = 2200           # 输出点数（每点 9 字节, 2200 点 ≈ 20KB/帧）
OUT_HZ = 10.0               # 引擎最高计算频率(双目 30fps 输入, 每 3 帧取 1 对)
WANT_TTL = 6.0              # 多久没人拉 /api/depth 就停机(秒)
Z_MIN, Z_MAX = 0.15, 4.0    # 有效深度窗口(m)，45mm 基线在这个范围内才有意义
DISP_MIN = 0.4              # 小于这个(亚像素)视差当无效，避免"无穷远"噪声
MIN_VALID = 0.015           # 有效像素低于这个比例就当"没匹配上"
SHEAR_WARN = 0.6            # 半幅每行偏移超过这个(px/row)就报输入异常

# 每个点: x,y,z (int16, mm) + r,g,b (u8) = 9 字节
PACK_DT = np.dtype([("x", "<i2"), ("y", "<i2"), ("z", "<i2"),
                    ("r", "u1"), ("g", "u1"), ("b", "u1")])


def estimate_focal(width, fov_deg):
    """由水平视场角反算焦距(px)。标定后可以不用它。"""
    fov = min(150.0, max(20.0, float(fov_deg)))
    return (float(width) * 0.5) / np.tan(np.deg2rad(fov) * 0.5)


# ---- 标定文件（stereo_calib.json）加载：按 mtime 热加载，坏了就当没有 ----
_CALIB = {"key": None, "data": None, "err": ""}


def load_calib(path=None):
    """读标定文件，返回 dict 或 None。

    返回字段（全部 numpy，尺寸均为**全分辨率**下的值）：
        size=(w,h)  K=(3,3)  D=(n,)  K_r  D_r  R=(3,3)  T=(3,1)
        baseline_m  rms  created  src(路径)
    """
    import json
    p = path or CALIB_PATH
    try:
        st = os.stat(p)
    except OSError:
        _CALIB.update(key=None, data=None, err="")
        return None
    key = (p, st.st_mtime, st.st_size)
    if _CALIB["key"] == key:
        return _CALIB["data"]
    try:
        with open(p, "r") as f:
            raw = json.load(f)
        arr = np.array
        lf, rt = raw["left"], raw["right"]
        st_raw = raw["stereo"]
        d = {
            "size": tuple(int(v) for v in raw.get("image_size")),
            "K": arr(lf["K"], np.float64).reshape(3, 3),
            "D": arr(lf["D"], np.float64).ravel(),
            "K_r": arr(rt["K"], np.float64).reshape(3, 3),
            "D_r": arr(rt["D"], np.float64).ravel(),
            "R": arr(st_raw["R"], np.float64).reshape(3, 3),
            "T": arr(st_raw["T"], np.float64).reshape(3, 1),
            "baseline_m": float(st_raw["baseline_m"]),
            "rms": float(st_raw.get("rms", raw.get("rms", 0.0)) or 0.0),
            "created": str(raw.get("created", "")),
            "src": p,
        }
        if len(d["size"]) != 2 or d["baseline_m"] <= 0:
            raise ValueError("image_size / baseline_m 非法")
        _CALIB.update(key=key, data=d, err="")
        return d
    except Exception as e:                                     # noqa: BLE001
        _CALIB.update(key=key, data=None, err="%s: %s" % (type(e).__name__, e))
        print("[depth] 标定文件有问题, 退回 FOV 估算: %s" % _CALIB["err"],
              file=sys.stderr)
        return None


def calib_brief():
    """给 /api/status、/api/depth 用的标定摘要（不含大数组）。"""
    d = load_calib()
    if d is None:
        return {"calib": False, "calib_err": _CALIB["err"],
                "calib_path": CALIB_PATH}
    return {"calib": True, "calib_path": d["src"],
            "calib_created": d["created"], "calib_rms": round(d["rms"], 3),
            "calib_size": list(d["size"]),
            "baseline_m": d["baseline_m"],
            "fx": round(float(d["K"][0, 0]), 1),
            "fy": round(float(d["K"][1, 1]), 1),
            "cx": round(float(d["K"][0, 2]), 1),
            "cy": round(float(d["K"][1, 2]), 1)}


class StereoDepth(threading.Thread):
    """后台线程：收最新一对左右目 → SGBM → 点云 → 打包。"""

    name = "depth"

    def __init__(self, params=None, quiet=False):
        super(StereoDepth, self).__init__(daemon=True, name="depth")
        self._params = params          # mipi_webstream 的 Params 对象(有 .get())
        self._quiet = quiet
        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)

        self._pair = None              # (L, R, ts) 只保留最新一对
        self._want_until = 0.0
        self._res = None               # 最近一次打包好的结果(dict)
        self._err = ""

        self._proc_w = PROC_W_DEF
        self._ms = 0.0                 # compute 耗时 EMA
        self._fps = 0.0
        self._t_start = 0.0
        self._t_done = 0.0
        self._npts = 0
        self._sgbm = None
        self._sgbm_key = None
        # 输入侧诊断: 半幅每行累积偏移(px/row)。0 = 正常。
        self._shear = [0.0, 0.0]
        self._shear_tick = 0
        # 标定: (key, maps)。maps 是处理分辨率下的极线校正查找表。
        self._rect = None
        self._rect_key = None

    # ------------------------------------------------------------ 外部接口
    def wanted(self, now=None):
        """前端最近有没有在拉点云。没人在看就别算。"""
        return (now if now is not None else time.time()) < self._want_until

    def submit(self, left, right):
        """喂一对左右目帧（不阻塞、不拷贝）。

        ⚠ 只保留最新一对：深度只要"现在的画面"，排队反而会让点云越跟越旧。
        """
        now = time.time()
        if now >= self._want_until:
            return False
        with self._lock:
            self._pair = (left, right, now)
            self._cond.notify()
        return True

    def snapshot(self):
        """给 /api/depth：返回最近结果，并顺手把"有人在看"续期。"""
        now = time.time()
        self._want_until = max(self._want_until, now + WANT_TTL)
        with self._lock:
            r = dict(self._res) if self._res is not None else None
        if r is None:
            d = {"ok": False, "reason": "warming", "err": self._err,
                 "shear_l": round(self._shear[0], 2),
                 "shear_r": round(self._shear[1], 2)}
            d.update(calib_brief())
            return d
        r["age"] = round(now - (r.get("t_done") or now), 3)
        r["stale"] = r["age"] > 1.5
        return r

    def status(self):
        """给 /api/status 的轻量状态（不含点云本体）。"""
        now = time.time()
        with self._lock:
            has = self._res is not None
        st = {
            "ok": cv2 is not None and not self._err,
            "err": self._err,
            "has_data": has,
            "wanted": self.wanted(now),
            "proc_w": int(self._proc_w),
            "ms": round(self._ms, 1),
            "fps": round(self._fps, 1),
            "n": int(self._npts),
            "baseline_m": BASELINE_M,
            "shear_l": round(self._shear[0], 2),
            "shear_r": round(self._shear[1], 2),
        }
        st.update(calib_brief())
        return st

    # ------------------------------------------------------------ 线程主体
    def run(self):
        if cv2 is None:
            self._err = "cv2 不可用: %s" % _CV2_ERR
            if not self._quiet:
                print("[depth] %s" % self._err, file=sys.stderr)
            return
        while True:
            with self._lock:
                if self._pair is None:
                    self._cond.wait(0.3)
                pair = self._pair
                self._pair = None
            if pair is None:
                continue
            L, R, tsp = pair
            now = time.time()
            if now >= self._want_until:       # 没人看 -> 丢
                continue
            if now - tsp > 0.5:               # 太旧 -> 丢
                continue
            gap = (1.0 / OUT_HZ) - (now - self._t_start)
            if gap > 0.002:
                time.sleep(gap)
            self._t_start = time.time()
            try:
                res = self._compute(L, R, tsp)
            except Exception as e:                            # noqa: BLE001
                self._err = "%s: %s" % (type(e).__name__, e)
                if not self._quiet:
                    print("[depth] %s" % self._err, file=sys.stderr)
                time.sleep(0.2)
                continue
            if res is None:
                continue
            self._err = ""
            now2 = time.time()
            if self._t_done:
                dt = now2 - self._t_done
                if 0.0 < dt < 2.0:
                    self._fps = (self._fps * 0.7 + (1.0 / dt) * 0.3) \
                        if self._fps else 1.0 / dt
            self._t_done = now2
            res["fps"] = round(self._fps, 1)
            self._npts = res["n"]
            with self._lock:
                self._res = res

    # ------------------------------------------------------------ 参数
    def _fov(self):
        fov = DEFAULT_FOV
        if self._params is not None:
            try:
                fov = float(self._params.get().get("depth_fov", DEFAULT_FOV))
            except Exception:                                 # noqa: BLE001
                fov = DEFAULT_FOV
        return min(150.0, max(20.0, fov))

    def _get_sgbm(self, pw):
        key = int(pw)
        if self._sgbm is not None and self._sgbm_key == key:
            return self._sgbm
        bs = 5
        # 视差上限给足 128：45mm 基线下 128 视差 ≈ 0.16m 最近可测距离。
        # 搜索范围越大越慢，所以靠下面的自适应处理宽度来控负载。
        nd = min(MAX_DISP, max(16, (key // 16) * 16))
        self._sgbm = cv2.StereoSGBM_create(
            minDisparity=0,
            numDisparities=nd,
            blockSize=bs,
            P1=8 * bs * bs,
            P2=32 * bs * bs,
            disp12MaxDiff=1,
            uniquenessRatio=5,
            speckleWindowSize=80,
            speckleRange=2,
            preFilterCap=31,
            mode=cv2.STEREO_SGBM_MODE_SGBM_3WAY,
        )
        self._sgbm_key = key
        return self._sgbm

    # ------------------------------------------------------------ 标定
    def _rect_maps(self, cal, pw, ph):
        """极线校正查找表（按处理分辨率生成并缓存）。

        标定文件里的 K/D 是**全分辨率**的, 这里按 (pw/W, ph/H) 缩放后
        再算 R1/R2/P1/P2 —— 这样 512 宽的处理图与 1920 宽的标定完全等效。

        返回 (map_lx, map_ly, map_rx, map_ry, f, cx, cy)：
          f/cx/cy 是**校正后左目**在处理分辨率下的焦距与主点，
          视差也在同一分辨率下 → z = f*B/d 直接用。
        """
        if cv2 is None or cal is None:
            return None
        w, h = int(cal["size"][0]), int(cal["size"][1])
        if w <= 0 or h <= 0 or pw <= 0 or ph <= 0:
            return None
        key = (cal.get("created"), float(cal["baseline_m"]), pw, ph)
        if self._rect is not None and self._rect_key == key:
            return self._rect
        sx, sy = pw / float(w), ph / float(h)
        S = np.array([[sx, 0.0, 0.0], [0.0, sy, 0.0], [0.0, 0.0, 1.0]])
        K1 = S @ cal["K"]
        K2 = S @ cal["K_r"]
        size = (int(pw), int(ph))
        R1, R2, P1, P2, _Q, _roi1, _roi2 = cv2.stereoRectify(
            K1, cal["D"], K2, cal["D_r"], size, cal["R"], cal["T"],
            flags=cv2.CALIB_ZERO_DISPARITY, alpha=0)
        lx, ly = cv2.initUndistortRectifyMap(K1, cal["D"], R1, P1, size,
                                            cv2.CV_16SC2)
        rx, ry = cv2.initUndistortRectifyMap(K2, cal["D_r"], R2, P2, size,
                                            cv2.CV_16SC2)
        self._rect = (lx, ly, rx, ry, float(P1[0, 0]),
                      float(P1[0, 2]), float(P1[1, 2]))
        self._rect_key = key
        return self._rect

    # ------------------------------------------------------------ 输入诊断
    def _estimate_shear(self, g, maxs=8):
        """估计图中"每行累积平移 k(px/row)"。0 = 正常/不可信。

        FPGA 双目拼接右半幅实测每行多 2 个 word（-4 px/row @1920 宽），
        这一个数就能把"右目数据坏了"和"场景没纹理"区分开，所以留作诊断。

        ⚠ 必须比**【相邻两行**】：早先用"隔 18 行"比一次，位移被放大到 72 px，
          自然图像上相关峰只有 0.3~0.4，被下面 0.55 的门限全滤掉，活体
          一直报 shear=0 —— 结果垃圾点云照样画出来（已实测过这个坑）。

        两道门限，宁可报 0 也不误报：
          * 行相关峰中位数 < 0.55 -> 纹理太差, 不可信
          * 落在中位 ±1px 的样本不足 55% -> 不一致, 不可信
            （不能用 MAD：真实的 -4/-3/-5 分布 MAD 就是 1.0，会被误判成噪声）
        """
        h, w = g.shape
        # 只取中央半幅、40 对相邻行：全幅×119 对实测要 117ms（A72），
        # 会把深度线程卡一下；取景只影响"够不够有纹理"，不影响斜率。
        band = g[:, w // 4: 3 * w // 4]
        bw = band.shape[1]
        stride = max(8, h // 40)        # 只取 ~40 对相邻行，够统计又不慢
        est, peaks = [], []
        for y in range(stride, h - 2, stride):
            a = band[y].astype(np.float32)
            b = band[y + 1].astype(np.float32)
            if a.std() < 2.0 or b.std() < 2.0:
                continue
            a = a - a.mean()
            b = b - b.mean()
            na = float(np.sqrt((a * a).sum()))
            nb = float(np.sqrt((b * b).sum()))
            if na < 1e-3 or nb < 1e-3:
                continue
            corr = []
            for s in range(-maxs, maxs + 1):
                if s >= 0:
                    v = float((a[s:] * b[:bw - s]).sum())
                else:
                    v = float((a[:bw + s] * b[-s:]).sum())
                corr.append(v / (na * nb))
            i = int(np.argmax(corr))
            peaks.append(corr[i])
            if 1 < i < len(corr) - 1:      # 抛物线插值到亚像素
                y0, y1, y2 = corr[i - 1], corr[i], corr[i + 1]
                den = (y0 - 2.0 * y1 + y2)
                off = 0.5 * (y0 - y2) / den if abs(den) > 1e-9 else 0.0
                est.append((i - maxs) + max(-1.0, min(1.0, off)))
            else:
                est.append(float(i - maxs))
        if len(est) < 6 or float(np.median(peaks)) < 0.55:
            return 0.0
        e = np.array(est, dtype=np.float32)
        med = float(np.median(e))
        if float(np.mean(np.abs(e - med) <= 1.0)) < 0.55:
            return 0.0
        return med

    # ------------------------------------------------------------ 核心
    def _compute(self, L, R, tsp=None):
        t_begin = time.time()
        h, w = L.shape[:2]
        if R.shape[:2] != (h, w):
            R = cv2.resize(R, (w, h), interpolation=cv2.INTER_LINEAR)

        # 全分辨率上测"每行偏移"（低分辨率会因搜索窗饱和而误报 4px）
        # 前 3 帧立即测一次（一开就来），之后每 30 帧（~3s）复测。
        if self._shear_tick < 3 or self._shear_tick % 30 == 0:
            self._shear[0] = self._estimate_shear(
                cv2.cvtColor(L, cv2.COLOR_BGR2GRAY))
            self._shear[1] = self._estimate_shear(
                cv2.cvtColor(R, cv2.COLOR_BGR2GRAY))
        self._shear_tick += 1
        shear_l, shear_r = self._shear
        if max(abs(shear_l), abs(shear_r)) > SHEAR_WARN:
            # 半幅被逐行拖成斜条纹时，SGBM 出来的"视差"是纯噪声，点云毫无意义。
            # 与其画一坨乱点，不如明确报出来（前端会把这句话写在画面上）。
            who = "右目" if abs(shear_r) >= abs(shear_l) else "左目"
            k = shear_r if who == "右目" else shear_l
            self._err = "%s数据异常(每行 %.1f px 斜移), 请查 FPGA 行打包" \
                % (who, abs(k))
            return None

        pw = int(min(self._proc_w, w))
        ph = int(round(h * pw / float(w))) & ~1
        if ph < 16:
            return None
        # INTER_LINEAR（不用 INTER_AREA）：RK3576 上 AREA 没有 SIMD 路径，
        # 见 mipi_webstream._to_bgr 的实测注释（慢 17~20 倍）。
        sl = cv2.resize(L, (pw, ph), interpolation=cv2.INTER_LINEAR)
        sr = cv2.resize(R, (pw, ph), interpolation=cv2.INTER_LINEAR)

        # ---- 标定：有 stereo_calib.json 就做极线校正 + 用标定内参 ----
        cal = load_calib()
        if cal is not None and (int(cal["size"][0]), int(cal["size"][1])) != (int(w), int(h)):
            # 输入分辨率跟标定时不一致 -> 内参/校正表全都对不上, 宁可报错也不许乱猜
            self._err = ("标定按 %dx%d 做的, 当前输入 %dx%d; 请按该分辨率重新标定"
                         % (cal["size"][0], cal["size"][1], w, h))
            return None
        rc = self._rect_maps(cal, pw, ph) if cal is not None else None
        if rc is not None:
            sl = cv2.remap(sl, rc[0], rc[1], cv2.INTER_LINEAR)
            sr = cv2.remap(sr, rc[2], rc[3], cv2.INTER_LINEAR)
            f = rc[4]
            cx_p, cy_p = rc[5], rc[6]
            f_full = f * (float(w) / pw)
            base_m = float(cal["baseline_m"])
            fov = 2.0 * np.rad2deg(np.arctan2(w * 0.5, f_full)) if f_full > 0 else 0.0
            ck = True
        else:
            fov = self._fov()
            f_full = estimate_focal(w, fov)
            f = f_full * (pw / float(w))
            cx_p, cy_p = pw * 0.5, ph * 0.5
            base_m = BASELINE_M
            ck = False
        gl = cv2.cvtColor(sl, cv2.COLOR_BGR2GRAY)
        gr = cv2.cvtColor(sr, cv2.COLOR_BGR2GRAY)

        t_algo = time.time()          # 只统计"匹配+反投影", 不含上面的测斜
        sgbm = self._get_sgbm(pw)
        disp = sgbm.compute(gl, gr).astype(np.float32) / 16.0
        disp = cv2.medianBlur(disp, 5)

        with np.errstate(divide="ignore", invalid="ignore"):
            z = (f * base_m) / disp
        ok = np.isfinite(z) & (disp > DISP_MIN) & (z > Z_MIN) & (z < Z_MAX)
        nvalid = int(ok.sum())
        valid_ratio = nvalid / float(pw * ph)
        if valid_ratio < MIN_VALID:
            # 匹配不上就明确返回 None，让前端显示原因，而不是画一坨噪点
            self._err = "匹配失败(有效像素 %.1f%%)" % (valid_ratio * 100.0)
            return None

        zv = z[ok]
        # 只在 1/5 的样本上求分位数：排序 3 万个数 ~2ms，全量要 8ms 以上
        lo, med, hi = np.percentile(zv[::5] if zv.size > 5000 else zv,
                                    [8.0, 50.0, 92.0])

        idx = np.flatnonzero(ok.ravel())
        step = max(1, idx.size // TARGET_PTS)
        idx = idx[::step]
        n = int(idx.size)
        if n < 16:
            return None

        u = (idx % pw).astype(np.float32)
        v = (idx // pw).astype(np.float32)
        zz = z.ravel()[idx]
        xx = (u - cx_p) * zz / f
        yy = (v - cy_p) * zz / f
        cols = sl.reshape(-1, 3)[idx]

        arr = np.empty(n, PACK_DT)
        for name, val in (("x", xx), ("y", yy), ("z", zz)):
            mm = np.clip(val * 1000.0, -32767, 32767).astype(np.int32)
            arr[name] = mm.astype(np.int16)
        arr["r"] = cols[:, 2]
        arr["g"] = cols[:, 1]
        arr["b"] = cols[:, 0]

        # 自适应负载: 太慢就缩处理宽度, 太快就放大（点更密）
        ms = (time.time() - t_algo) * 1000.0
        self._ms = self._ms * 0.8 + ms * 0.2 if self._ms else ms
        if ms > 110 and self._proc_w > PROC_W_MIN:
            self._proc_w = max(PROC_W_MIN, self._proc_w - 64)
        elif ms < 45 and self._proc_w < PROC_W_MAX:
            self._proc_w = min(PROC_W_MAX, self._proc_w + 64)

        warn = ""
        if max(abs(shear_l), abs(shear_r)) > SHEAR_WARN:
            who = "右目" if abs(shear_r) >= abs(shear_l) else "左目"
            warn = "%s数据异常(每行 %.1f px 斜移)" % (who, abs(
                shear_r if who == "右目" else shear_l))

        return {
            "ok": True,
            "t_done": time.time(),
            "t_cap": round(float(tsp or 0.0), 3),
            "n": n,
            "valid": round(valid_ratio, 4),
            "zmin": round(float(lo), 3),
            "zmed": round(float(med), 3),
            "zmax": round(float(hi), 3),
            "w": int(w), "h": int(h),
            "pw": int(pw), "ph": int(ph),
            "focal_px": round(float(f_full), 1),
            "fov_deg": round(fov, 1),
            "baseline_m": base_m,
            "calib": ck,
            "alg": "sgbm",
            "ms": round(ms, 1),
            "shear_l": round(float(shear_l), 2),
            "shear_r": round(float(shear_r), 2),
            "warn": warn,
            "pts": base64.b64encode(arr.tobytes()).decode("ascii"),
        }


# ==========================================================================
#  自检：合成一对"已知视差"的纹理，验证 z = f*B/d 与耗时
# ==========================================================================
def _selftest(proc_w=512, disp_px=32, rounds=10):
    if cv2 is None:
        print("cv2 不可用: %s" % _CV2_ERR)
        return 1
    rng = np.random.RandomState(7)
    w = int(proc_w)
    h = (w * 9 // 16) & ~1
    # 低频随机纹理（放大后才有足够的块状结构给 SGBM）
    src = (rng.rand(h // 4 + 2, (w + disp_px) // 4 + 2, 3) * 255).astype(np.uint8)
    tex = cv2.resize(src, (w + disp_px, h), interpolation=cv2.INTER_LINEAR)
    L = tex[:, :w].copy()
    R = tex[:, disp_px:disp_px + w].copy()

    eng = StereoDepth(None, quiet=True)
    eng._proc_w = w
    fov = DEFAULT_FOV
    f_full = estimate_focal(w, fov)
    z_true = f_full * BASELINE_M / float(disp_px)

    res = None
    t0 = time.time()
    for _ in range(max(1, rounds)):
        res = eng._compute(L, R, time.time())
    ms = (time.time() - t0) * 1000.0 / max(1, rounds)
    if not res:
        print("自检失败: 没有产生点云")
        return 1
    err = abs(res["zmed"] - z_true) / z_true
    print("自检 (合成对 %dx%d, 已知视差 %d px)" % (w, h, disp_px))
    print("  焦距 f       = %.1f px  (FOV %.0f°)" % (f_full, fov))
    print("  理论 z       = %.4f m" % z_true)
    print("  估计 z(中位) = %.4f m   误差 %.2f%%" % (res["zmed"], err * 100))
    print("  有效像素占比 = %.1f%%   点数 %d" % (res["valid"] * 100, res["n"]))
    print("  每帧耗时     = %.1f ms  ->  %.1f fps" % (ms, 1000.0 / max(1e-3, ms)))
    if err > 0.03:
        print("  ✗ 误差超过 3%，请检查公式/缩放")
        return 1
    print("  ✓ 通过")
    return 0


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="双目深度引擎")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--proc-w", type=int, default=PROC_W_DEF)
    ap.add_argument("--disp", type=int, default=32)
    ap.add_argument("--rounds", type=int, default=10)
    a = ap.parse_args()
    if a.selftest:
        sys.exit(_selftest(a.proc_w, a.disp, a.rounds))
    print("stereo_depth.py: 用 --selftest 自检；作为模块由 mipi_webstream 调用。")
