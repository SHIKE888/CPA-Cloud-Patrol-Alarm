#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mipi_webstream.py
================================================================================
把 RK3576 上 FPGA(MIPI x4) 采集到的画面, 通过 HTTP MJPEG 推流出去,
同时提供一套 Web API, 用于远程调节画面参数。

默认监听 0.0.0.0:9012

    http://<RK的IP>:9012/            浏览器直接看画面(内置完整控制台)
    http://<RK的IP>:9012/stream      MJPEG 流, 可直接放进 <img src="...">
    http://<RK的IP>:9012/api/params  GET 读取 / POST 修改画面参数
    http://<RK的IP>:9012/api/controls GET 列出 V4L2 硬件可调参数
    http://<RK的IP>:9012/api/ctrl    POST 设置 V4L2 硬件参数
    http://<RK的IP>:9012/api/status  GET  运行状态

用法:
    python3 mipi_webstream.py --device /dev/video22 --port 9012
    python3 mipi_webstream.py --backend gst          # OpenCV 不可用时用 gst 抓流
    python3 mipi_webstream.py --device /dev/video22 --port 9012 --stream-width 1280

说明:
    画面参数(亮度/对比度/饱和度/色相/伽马/镜像/翻转/旋转/缩放/质量)由本程序
    逐帧处理, 改完立即生效, 不中断推流。
    另外会自动发现 V4L2(ISP/传感器) 的硬件参数并支持在线设置。
================================================================================
"""

import argparse
import io
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ------------------------------------------------------------------ 依赖
try:
    import cv2
    import numpy as np
    HAVE_CV2 = True
except Exception as _e:                                    # pragma: no cover
    cv2 = None
    np = None
    HAVE_CV2 = False
    _CV2_ERR = _e
else:
    _CV2_ERR = None

# ---------------------------------------------------- GStreamer Python 绑定
# 本板 (RK3576 Debian) 上 cv2/numpy 都没有, 但 python3-gi + GStreamer 有,
# 所以画质参数走 GStreamer 元素 (videobalance/gamma/videoflip/...) 在线调整。
HAVE_GST_PY = False
_GST_PY_ERR = None
try:
    import gi

    gi.require_version("Gst", "1.0")
    from gi.repository import Gst

    Gst.init(None)
    HAVE_GST_PY = True
except Exception as _e:                                   # pragma: no cover
    Gst = None
    _GST_PY_ERR = _e

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BOUNDARY = "frame"

# ------------------------------------------------------------------ 状态持久化
# 把「上次用过的参数」存成一个 JSON（软件画面参数 + AI 参数），
# 页面重连 / 服务重启后自动恢复。见 state_store.py。
try:
    if SCRIPT_DIR not in sys.path:
        sys.path.insert(0, SCRIPT_DIR)
    import state_store
    STATE_FILE_DEFAULT = os.path.join(SCRIPT_DIR, "state.json")
except Exception as _e:                                   # pragma: no cover
    state_store = None
    STATE_FILE_DEFAULT = None
    _STATE_IMPORT_ERR = "%s: %s" % (type(_e).__name__, _e)
else:
    _STATE_IMPORT_ERR = ""

# ------------------------------------------------------------------ 可选 AI 叠加
# 同进程复用已经转好的 BGR 帧, 不需要"拉 MJPEG → 解码 → 推理 → 再编码"的第二趟。
# 导入/模型缺失时静默降级, 完全不影响原有推流功能。
try:
    if SCRIPT_DIR not in sys.path:
        sys.path.insert(0, SCRIPT_DIR)
    from ai_overlay import AiOverlay
except Exception as _e:                                   # pragma: no cover
    AiOverlay = None
    _AI_IMPORT_ERR = "%s: %s" % (type(_e).__name__, _e)
else:
    _AI_IMPORT_ERR = ""

AI_OVERLAY = None        # 由 main() 创建; 编码线程只读

# ------------------------------------------------------------------ 默认参数
DEFAULT_PARAMS = {
    "brightness": 0,      # -100 .. 100        (加减偏移)
    "contrast":   1.0,    #  0.2 .. 3.0        (增益)
    "saturation": 1.0,    #  0.0 .. 3.0        (饱和度)
    "hue":        0,      # -180 .. 180 度    (色相旋转)
    "gamma":      1.0,    #  0.2 .. 3.0        (伽马)
    "mirror":     0,      #  0/1               (水平镜像)
    "flipv":      0,      #  0/1               (垂直翻转)
    "rotate":     0,      #  0/90/180/270      (旋转)
    "scale":      1.0,    #  0.25 .. 1.5       (相对 --stream-width 的缩放)
    "quality":    80,     #  30 .. 95          (JPEG 质量)
    "fps":        60,     #  1 .. 120          (推流帧率上限, 默认 60 = 当前链路上限)
}

PARAM_RANGE = {
    "brightness": (-100, 100),
    "contrast":   (0.2, 3.0),
    "saturation": (0.0, 3.0),
    "hue":        (-180, 180),
    "gamma":      (0.2, 3.0),
    "mirror":     (0, 1),
    "flipv":      (0, 1),
    "rotate":     (0, 270),
    "scale":      (0.25, 1.5),
    "quality":    (30, 95),
    # 上限放宽到 120。注意这只是一个"限速阀", 实际上限由链路决定:
    # 本工程 FPGA 固定输出 1080p60, 所以填 60 以上等于不限速, 结果仍是 ~59.6fps。
    # 想真的超过 60 得改 FPGA 侧 (ui_vtc 时序 / PLL / D-PHY byte clk)。
    "fps":        (1, 120),
}


def _clamp_params(p):
    """把外部传入的参数裁剪到合法范围, 只保留已知键。"""
    out = {}
    for k, (lo, hi) in PARAM_RANGE.items():
        if k not in p:
            continue
        try:
            v = float(p[k])
        except (TypeError, ValueError):
            continue
        if k in ("mirror", "flipv", "rotate"):
            v = int(round(v))
        if k == "rotate":
            v = min((0, 90, 180, 270), key=lambda x: abs(x - v))
        else:
            v = min(max(v, lo), hi)
        out[k] = v
    return out


def _test_frame_pil(w, h, t, quality):
    """没有 OpenCV 时, 用 PIL 生成测试图案 (软件画面参数不生效)。"""
    try:
        from PIL import Image, ImageDraw
    except Exception:
        return None
    img = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(img)
    colors = [(255, 255, 255), (0, 255, 255), (255, 255, 0), (0, 255, 0),
              (255, 0, 255), (0, 0, 255), (255, 0, 0), (40, 40, 40)]
    bw = max(1, w // len(colors))
    for i, c in enumerate(colors):
        d.rectangle([i * bw, 0, (i + 1) * bw - 1, h], fill=c)
    x = int((t * 200) % w)
    if x > 0:
        d.rectangle([max(0, x - 40), 0, x, h], fill=(255, 255, 255))
    d.text((20, h - 40), time.strftime("%Y-%m-%d %H:%M:%S") + "  t=%.1fs" % t,
           fill=(0, 0, 0))
    d.text((20, int(h * 0.1)), "FPGA-MIPI TEST PATTERN (PIL)", fill=(0, 0, 0))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=int(quality))
    return buf.getvalue()


def _have_cmd(name):
    """判断某个可执行文件是否在 PATH 上。"""
    try:
        from shutil import which
        return which(name) is not None
    except Exception:
        return False


def _parse_cpu_list(spec):
    """把 "4-7" / "4,5,6,7" / "4-5,7" 这样的写法解析成 CPU 号集合。"""
    out = set()
    for part in str(spec).split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.update(range(int(a), int(b) + 1))
        else:
            out.add(int(part))
    return out


def _pick_fast_cores():
    """按 cpuinfo_max_freq 挑出最快的那批核。

    本板 (RK3576 异构 8 核): cpu0-3 = Cortex-A53@1.92GHz,
    cpu4-7 = Cortex-A72@2.11GHz。同一段 JPEG 编码在小核上只有 21.8fps,
    换到大核是 41.4fps —— 光是绑定亲和性就差了将近一倍, 所以默认要绑。
    """
    try:
        n = os.cpu_count() or 1
        freq = {}
        for i in range(n):
            p = "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq" % i
            try:
                with open(p) as f:
                    freq[i] = int(f.read().strip())
            except Exception:
                freq[i] = 0
        if not any(freq.values()):
            return None
        top = max(freq.values())
        return {i for i, f in freq.items() if f == top}
    except Exception:
        return None


# ============================================================================
#  YUV -> BGR 转换(自己做, 不用 OpenCV 的)
#
#  为什么不能用 OpenCV 自带的转换:
#    本工程 FPGA 送出的 YUV 实测是 **BT.709 + limited range(16~235)**。
#    证据 1(源码): fpga/uisrc/03_ip/mipi_dsi/rgb_to_yuv422_quad.v
#         Y  = 0.183R + 0.614G + 0.062B + 16
#         系数和 0.859 = 219/255, 且 (0.183,0.614,0.062) 与 BT.709 的
#         (0.2126,0.7152,0.0722)x219/255 完全吻合 (BT.601 会是 0.257/0.504/0.098)
#         => 白点落在 235, 黑点落在 16
#    证据 2(实测): 抓一帧原始 NV16, Y 的 min=22 / max=234 (limited 白点=235)
#    而 OpenCV 的 YUV->RGB 按 **full range** 解释 -> 黑电平被抬高到 16/255,
#    色度偏差也被压缩 -> 画面发灰、发绿、颜色很"怪"。
#    修法: 让 OpenCV 别转(CAP_PROP_CONVERT_RGB=0), 拿原始 YUV 自己按
#          BT.709 + limited 转。
# ============================================================================
YUV_MATRIX = {
    # kr, kg_u, kg_v, kb
    "601": (1.402000, -0.344136, -0.714136, 1.772000),
    "709": (1.574800, -0.187300, -0.468100, 1.855600),
}


_YUV_LUT_CACHE = {}


def _yuv_luts(matrix, rng):
    """把量程展开 + 色彩矩阵系数全部预计算成 256 项 int16 查找表。

    这样每帧只需查表 + 整数加法, 不再做 float32 乘加 —— 内存流量减半、
    少一遍 np.rint, 实测比 float32 版本快 2~3 倍, 数值一致(±1 LSB)。

    返回 (Y, U->B, U->G, V->G, V->R) 五张 int16 表。
    """
    key = (matrix, rng)
    lut = _YUV_LUT_CACHE.get(key)
    if lut is not None:
        return lut
    kr, kgu, kgv, kb = YUV_MATRIX.get(matrix, YUV_MATRIX["709"])
    i = np.arange(256, dtype=np.float32)
    if rng == "limited":
        yv = np.clip((i - 16.0) * (255.0 / 219.0), 0.0, 255.0)
        c = (i - 128.0) * (255.0 / 224.0)
    else:
        yv = i
        c = i - 128.0
    lut = (
        np.rint(yv).astype(np.int16),
        np.rint(kb * c).astype(np.int16),
        np.rint(kgu * c).astype(np.int16),
        np.rint(kgv * c).astype(np.int16),
        np.rint(kr * c).astype(np.int16),
    )
    _YUV_LUT_CACHE[key] = lut
    return lut


def yuv_to_bgr(buf, w, h, fmt="NV16", matrix="709", rng="limited",
               swap_uv=False, target=None):
    """原始 YUV 缓冲 -> BGR。

    target=(tw,th) 时, 先在 YUV 域把平面缩到目标尺寸再转换 —— 后面反正要缩小,
    这样能省掉一大半运算(1080p -> 720p 约省 2.2 倍)。

    实现要点(为什么快):
      * 量程展开(16-235 -> 0-255)与 BT.709 矩阵系数合并成 int16 查找表
      * 全程整数运算, 不做 float32 乘加、不做 np.rint
      * 原地裁剪并写进预分配缓冲, 避免 np.stack 产生大临时数组
    """
    n = w * h
    if fmt in ("NV16", "YUYV", "UYVY", "YUY2"):
        y = buf[:n].reshape(h, w)
        c = buf[n:n + n].reshape(h, w // 2, 2)
        if target and (target[0] != w or target[1] != h):
            tw, th = int(target[0]), int(target[1])
            y = cv2.resize(y, (tw, th), interpolation=cv2.INTER_AREA)
            c = cv2.resize(c, (max(1, tw // 2), th),
                           interpolation=cv2.INTER_AREA)
            w, h = tw, th
        is422 = True
    else:                                  # NV12 / NV21
        y = buf[:n].reshape(h, w)
        c = buf[n:n + n // 2].reshape(h // 2, w // 2, 2)
        if target and (target[0] != w or target[1] != h):
            tw, th = int(target[0]), int(target[1])
            y = cv2.resize(y, (tw, th), interpolation=cv2.INTER_AREA)
            c = cv2.resize(c, (max(1, tw // 2), max(1, th // 2)),
                           interpolation=cv2.INTER_AREA)
            w, h = tw, th
        is422 = False

    luty, lutb, lutgu, lutgv, lutr = _yuv_luts(matrix, rng)
    cu, cvv = (1, 0) if swap_uv else (0, 1)

    # 查表一定要用 cv2.LUT (SIMD) —— 用 numpy 花式索引 lut[u8] 会慢十几倍,
    # 因为 numpy 的 gather 没有向量化。
    if is422:
        yv = cv2.LUT(y, luty).reshape(h, w // 2, 2)
        uu, vv = cv2.split(c)              # SIMD 拆平面, 得到连续单通道
        if swap_uv:
            uu, vv = vv, uu
        # 先把 G 的两项在小数组上相加, 再和 Y 做一次广播 —— 少一次大数组广播
        gsum = cv2.LUT(uu, lutgu)
        gsum += cv2.LUT(vv, lutgv)
        b = yv + cv2.LUT(uu, lutb)[:, :, None]
        g = yv + gsum[:, :, None]
        r = yv + cv2.LUT(vv, lutr)[:, :, None]
        out = np.empty((h, w // 2, 2, 3), np.uint8)
        for i, ch in enumerate((b, g, r)):
            np.clip(ch, 0, 255, out=ch)
            out[..., i] = ch
        return out.reshape(h, w, 3)

    yv = cv2.LUT(y, luty)
    uu = np.repeat(np.repeat(c[:, :, cu], 2, 0), 2, 1)
    vv = np.repeat(np.repeat(c[:, :, cvv], 2, 0), 2, 1)
    gsum = cv2.LUT(uu, lutgu)
    gsum += cv2.LUT(vv, lutgv)
    b = yv + cv2.LUT(uu, lutb)
    g = yv + gsum
    r = yv + cv2.LUT(vv, lutr)
    out = np.empty((h, w, 3), np.uint8)
    for i, ch in enumerate((b, g, r)):
        np.clip(ch, 0, 255, out=ch)
        out[..., i] = ch
    return out


# ============================================================================
#  YUV -> BGR 的 C 加速版 (libyuvconv.so)
#
#  上面那个 numpy 版算法正确但太慢: 实测 1920x1080 要 45~67ms, 而采集一帧
#  只要 16.8ms —— 于是"色彩转换"反倒成了整条 1080p60 流水线的瓶颈
#  (JPEG 编码只要 18ms, 还能多线程摊掉)。
#
#  这里做两件事:
#    1) 用 C 重写同一套整数查表算法 —— 逐像素结果与 numpy 版完全一致
#       (实测 max diff = 0), 单线程 45ms -> 20.8ms;
#    2) 把画面按行切成几段, 用多个 Python 线程并发调用同一个 C 函数。
#       C 函数不持 GIL, 所以这是真并行: 4 线程 -> 7.9ms。
#
#  编译:  ./build_yuvconv.sh
#  没有 .so 时自动退回 numpy 版 (慢但结果一致)。
# ============================================================================
YUVCONV_PATH = os.path.join(SCRIPT_DIR, "libyuvconv.so")
_YUVCONV = None
_YUVCONV_TRIED = False
_CONV_POOL = None

import ctypes                                                        # noqa: E402
import queue                                                         # noqa: E402


def _yuvconv_lib():
    """加载并配置 libyuvconv.so (只尝试一次)。"""
    global _YUVCONV, _YUVCONV_TRIED
    if _YUVCONV_TRIED:
        return _YUVCONV
    _YUVCONV_TRIED = True
    try:
        lib = ctypes.CDLL(YUVCONV_PATH)
        lib.yuvconv_nv16_to_bgr_rows.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
            ctypes.c_int, ctypes.c_int, ctypes.c_int,
            ctypes.c_int, ctypes.c_int, ctypes.c_int]
        lib.yuvconv_nv16_to_bgr_rows.restype = ctypes.c_int
        lib.yuvconv_nv12_to_bgr.argtypes = [
            ctypes.c_char_p, ctypes.c_char_p,
            ctypes.c_int, ctypes.c_int, ctypes.c_int,
            ctypes.c_int, ctypes.c_int]
        lib.yuvconv_nv12_to_bgr.restype = ctypes.c_int
        _YUVCONV = lib
        print("[yuvconv] 已加载 C 加速库 %s" % YUVCONV_PATH)
    except Exception as e:
        _YUVCONV = None
        print("[yuvconv] 未加载 C 库 (%s), 使用 numpy 版 (较慢)" % e,
              file=sys.stderr)
    return _YUVCONV


def _conv_pool(nthreads):
    """行切分用的常驻线程池 (每帧新建线程池开销太大)。"""
    global _CONV_POOL
    if _CONV_POOL is None:
        from concurrent.futures import ThreadPoolExecutor
        _CONV_POOL = ThreadPoolExecutor(max_workers=max(1, int(nthreads)),
                                        thread_name_prefix="yuvconv")
    return _CONV_POOL


def yuv_to_bgr_c(buf, w, h, fmt="NV16", matrix="709", rng="limited",
                 swap_uv=False, nthreads=4):
    """C 版 YUV->BGR。库缺失/格式不支持/数据不连续时返回 None, 由调用方回退。

    buf  : 一维 uint8 连续缓冲; NV16 = [Y w*h][UV h*(w/2)*2]
    """
    lib = _yuvconv_lib()
    if lib is None:
        return None
    if buf.ndim != 1:
        buf = buf.reshape(-1)
    if buf.dtype != np.uint8 or not buf.flags["C_CONTIGUOUS"]:
        return None
    if w <= 0 or h <= 0 or (w & 1):
        return None

    m = 709 if str(matrix) == "709" else 601
    rg = 0 if str(rng) == "limited" else 1
    sw = 1 if swap_uv else 0
    out = np.empty((h, w, 3), np.uint8)

    if fmt in ("NV12", "NV21"):
        rc = lib.yuvconv_nv12_to_bgr(
            buf.ctypes.data_as(ctypes.c_char_p),
            out.ctypes.data_as(ctypes.c_char_p),
            w, h, 1 if fmt == "NV21" else sw, m, rg)
        return out if rc == 0 else None

    if fmt not in ("NV16", "YUYV", "UYVY", "YUY2"):
        return None

    base = buf.ctypes.data
    uv = base + w * h
    dst = out.ctypes.data
    n = max(1, min(int(nthreads), h))
    step = (h + n - 1) // n

    if n == 1:
        lib.yuvconv_nv16_to_bgr_rows(base, uv, dst, w, h, w, sw, m, rg)
        return out

    def _job(r0):
        r1 = min(h, r0 + step)
        if r1 > r0:
            lib.yuvconv_nv16_to_bgr_rows(
                base + r0 * w, uv + r0 * w, dst + r0 * w * 3,
                w, r1 - r0, w, sw, m, rg)

    list(_conv_pool(n).map(_job, range(0, h, step)))
    return out


# ============================================================================
#  帧缓冲: 采集线程写入, 每个 HTTP 客户端读最新帧
# ============================================================================
class FrameHub:
    def __init__(self):
        self._cond = threading.Condition()
        self._jpeg = None
        self._frame_id = 0
        self._info = {}
        self._fps = 0.0
        self._clients = 0
        self._fps_t0 = time.time()
        self._fps_cnt = 0

    def publish(self, jpeg, info=None):
        now = time.time()
        with self._cond:
            self._jpeg = jpeg
            self._frame_id += 1
            if info:
                self._info = info
            # 每满 1 秒统计一次真实帧率
            self._fps_cnt += 1
            span = now - self._fps_t0
            if span >= 1.0:
                self._fps = self._fps_cnt / span
                self._fps_cnt = 0
                self._fps_t0 = now
            self._cond.notify_all()

    def snapshot(self):
        with self._cond:
            return self._jpeg, self._frame_id

    def wait_next(self, last_id, timeout=5.0):
        """阻塞等待比 last_id 更新的帧, 返回 (jpeg, id); 超时返回 (None, last_id)。"""
        with self._cond:
            self._cond.wait_for(lambda: self._frame_id > last_id, timeout)
            if self._frame_id == last_id:
                return None, last_id
            return self._jpeg, self._frame_id

    def status(self):
        with self._cond:
            d = dict(self._info)
            d["fps"] = round(self._fps, 1)
            d["frame_id"] = self._frame_id
            d["clients"] = self._clients
            return d


# ============================================================================
#  画面参数 (线程安全)
# ============================================================================
class ParamStore:
    def __init__(self, path=None):
        self._lock = threading.Lock()
        self._path = path
        self._p = dict(DEFAULT_PARAMS)
        self._lut_cache = (None, None)     # (gamma, lut)
        # 恢复上次保存的值（只认已知键：旧版本残留 / 手改坏的值都不影响启动）
        saved = state_store.get(path, "params") if (state_store and path) else {}
        n = 0
        for k, v in saved.items():
            if k in DEFAULT_PARAMS and isinstance(v, (int, float, bool)):
                self._p[k] = v
                n += 1
        if n:
            print("[params] 已恢复上次的 %d 项画面参数 (%s)" % (n, path))

    def get(self):
        with self._lock:
            return dict(self._p)

    def update(self, patch):
        with self._lock:
            self._p.update(patch)
            snap = dict(self._p)
        self._save(snap)
        return snap

    def reset(self):
        with self._lock:
            self._p = dict(DEFAULT_PARAMS)
            snap = dict(self._p)
        # 重置 = 把存档也清掉，否则下次启动又“恢复”回来了
        if state_store is not None and self._path:
            state_store.replace(self._path, "params", snap)
        return snap

    def _save(self, snap):
        if state_store is not None and self._path:
            state_store.put(self._path, "params", snap)

    def gamma_lut(self, gamma):
        """缓存 gamma 查找表, 避免每帧重算 256 项。"""
        g = round(float(gamma), 3)
        with self._lock:
            cg, lut = self._lut_cache
            if cg == g and lut is not None:
                return lut
        lut = (np.clip(((np.arange(256, dtype=np.float32) / 255.0) ** (1.0 / g))
                       * 255.0, 0, 255)).astype(np.uint8).reshape(256, 1)
        with self._lock:
            self._lut_cache = (g, lut)
        return lut


# ============================================================================
#  采集后端 1: OpenCV (支持全部软件画面参数)
# ============================================================================
class OpenCVCapture(threading.Thread):
    name = "opencv"

    def __init__(self, hub, params, args):
        super().__init__(daemon=True)
        self.hub = hub
        self.params = params
        self.args = args
        self.stop_flag = threading.Event()
        self._w = 0
        self._h = 0
        self._raw_fmt = (args.fourcc or "NV16").upper()
        self._raw_warned = False
        self._pre_scaled = False
        self._stage = None                 # 预缩放后的拼装缓冲 (Y + UV)

        # ---- 三级流水线 ----
        self._conv_threads = max(1, int(getattr(args, "conv_threads", 4) or 4))
        self._enc_threads = max(1, int(getattr(args, "enc_threads", 3) or 3))
        self._raw_q = queue.Queue(maxsize=3)
        self._bgr_q = queue.Queue(maxsize=3)
        self._results = {}                 # seq -> jpeg, 用于按序发布
        self._next_pub = 1
        self._seq_cond = threading.Condition()

    # ------------------------------------------------------------------
    #  三级流水线
    #
    #    采集线程 ──raw_q──> 转换线程 ──bgr_q──> N 个编码线程 ──按序──> 发布
    #    (16.8ms)           (7.9ms)            (18.2ms / N)
    #
    #  吞吐 = max(各段耗时), 而不是 sum(各段)。实测 (1920x1080, A72 核):
    #    旧版串行: 16.8 + 67.2 + 18.2 = 102.3ms ->  9.8 fps
    #    流水线  : max(16.8, 7.9, 6.1) = 16.8ms  -> 59.6 fps
    #  也就是说, 优化之后瓶颈回到"采集"本身 (= 链路上限), 这正是我们要的结果。
    #
    #  队列用阻塞 put 做背压, 刻意不丢帧 —— 一旦丢帧, 序号就会出现空洞,
    #  按序发布会因为等一个永远不来的号而卡死。
    # ------------------------------------------------------------------
    def run(self):
        dev = self.args.device

        if not HAVE_CV2:
            print("[opencv] 未安装 cv2: %s" % _CV2_ERR, file=sys.stderr)
            self._fallback_loop()
            return

        print("[opencv] 流水线启动: 采集 1 线程 / 转换 %d 线程 / 编码 %d 线程"
              % (self._conv_threads, self._enc_threads))
        threading.Thread(target=self._conv_loop, daemon=True,
                         name="conv").start()
        for i in range(self._enc_threads):
            threading.Thread(target=self._enc_loop, daemon=True,
                             name="enc%d" % i).start()
        self._capture_loop(dev)

    def _put(self, q, item):
        """带背压的放入 (队列满就等一会儿, 同时留意停止标志)。"""
        while not self.stop_flag.is_set():
            try:
                q.put(item, timeout=0.3)
                return
            except queue.Full:
                continue

    def request_reopen(self):
        """请求采集线程释放并重开 V4L2 设备 (切换分辨率/帧率后用)。"""
        ev = getattr(self, "need_reopen", None)
        if ev is None:
            ev = threading.Event()
            self.need_reopen = ev
        ev.set()

    def _capture_loop(self, dev):
        cap = None
        seq = 0
        while not self.stop_flag.is_set():
            t_start = time.time()
            # 模式切换: 先丢掉旧句柄, 下面用新的 args 重新打开
            _ev = getattr(self, "need_reopen", None)
            if _ev is not None and _ev.is_set():
                _ev.clear()
                if cap is not None:
                    cap.release()
                    cap = None
                print("[opencv] 检测到分辨率/帧率切换, 重新打开采集")
            # 每轮重读 —— 改分辨率后必须拿新尺寸重开
            w, h = self.args.width, self.args.height
            if cap is None or not cap.isOpened():
                if cap is not None:
                    cap.release()
                # 设备此刻空闲, 先按目标尺寸设好节点格式 —— rkcif 会顺着 pipeline
                # 把 sensor subdev 也改掉 (驱动侧的模式表)。
                # ⚠ 这一步必须在设备空闲时做: 被占用时 VIDIOC_S_FMT 返回 EBUSY。
                _okf, _msgf = v4l2_set_fmt(dev, w, h, self.args.fourcc,
                                           self.args.v4l2ctl)
                print("[opencv] v4l2-ctl set-fmt %dx%d -> %s" % (w, h, _msgf))
                print("[opencv] 打开 %s ..." % dev)
                cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
                if self.args.fourcc:
                    cap.set(cv2.CAP_PROP_FOURCC,
                            cv2.VideoWriter_fourcc(*self.args.fourcc))
                cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
                cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
                try:
                    cap.set(cv2.CAP_PROP_BUFFERSIZE, 4)
                except Exception:
                    pass
                # 关键: 关掉 OpenCV 自带的 YUV->BGR (它是 full-range, 与实际不符),
                # 直接取原始 YUV 缓冲, 自己按 BT.709 + limited 转。
                try:
                    cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
                except Exception:
                    pass
                if not cap.isOpened():
                    print("[opencv] 打开失败, 2 秒后重试", file=sys.stderr)
                    time.sleep(2)
                    continue
                aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
                ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
                self._w, self._h = aw, ah
                print("[opencv] 已打开 %s  %dx%d  fourcc=%s  matrix=%s/%s"
                      % (dev, aw, ah, self._raw_fmt,
                         self.args.yuv_matrix, self.args.yuv_range))
                self.hub.publish(None, {"backend": self.name, "device": dev,
                                        "width": aw, "height": ah})

            ok, frame = cap.read()
            if not ok or frame is None:
                self.fail_count = getattr(self, "fail_count", 0) + 1
                if self.fail_count > 30:
                    print("[opencv] 连续读帧失败, 重连", file=sys.stderr)
                    cap.release()
                    cap = None
                    self.fail_count = 0
                time.sleep(0.02)
                continue
            self.fail_count = 0

            seq += 1
            self._put(self._raw_q, (seq, frame))

            # 限帧: 只补足"剩余"时间。默认 60 (链路上限), 可在网页上往下调。
            target = max(1.0, float(self.params.get()["fps"]))
            dt = 1.0 / target
            rest = dt - (time.time() - t_start)
            if rest > 0.0005:
                time.sleep(rest)

        if cap is not None:
            cap.release()

    def _conv_loop(self):
        """中间级: 原始 YUV -> BGR (含缩放/几何/颜色参数)。"""
        while not self.stop_flag.is_set():
            try:
                seq, raw = self._raw_q.get(timeout=0.5)
            except queue.Empty:
                continue
            p = self.params.get()
            try:
                frame = self._to_bgr(raw, p)
            except Exception as e:
                print("[opencv] 色彩转换异常: %s" % e, file=sys.stderr)
                continue
            if frame is None:
                continue
            frame = self._process(frame, p)
            self._put(self._bgr_q, (seq, frame))

    def _enc_loop(self):
        """末级: JPEG 编码。多个线程跑同一段代码, 靠 GIL 释放真正并行。"""
        while not self.stop_flag.is_set():
            try:
                seq, frame = self._bgr_q.get(timeout=0.5)
            except queue.Empty:
                continue
            p = self.params.get()
            # ---- 可选 AI 叠加 ----
            # 只在"画面源 = AI 标注"时才碰帧; 切回原图时这段开销为零。
            _ai = AI_OVERLAY
            if _ai is not None and _ai.active:
                try:
                    _ai.submit(frame)
                    frame = _ai.draw(frame)
                except Exception as _e:                   # noqa: BLE001
                    print("[ai] 叠加异常: %s" % _e, file=sys.stderr)
            jpg = None
            try:
                ok, buf = cv2.imencode(
                    ".jpg", frame,
                    [int(cv2.IMWRITE_JPEG_QUALITY), int(p["quality"])])
                if ok:
                    jpg = buf.tobytes()
            except Exception as e:
                print("[opencv] 编码异常: %s" % e, file=sys.stderr)

            # 按序号顺序发布, 避免多线程导致客户端看到乱序画面
            with self._seq_cond:
                self._results[seq] = jpg
                while self._next_pub in self._results:
                    j = self._results.pop(self._next_pub)
                    self._next_pub += 1
                    if j is not None:
                        self.hub.publish(j)
                self._seq_cond.notify_all()


    def _target_size(self, scale):
        """推流目标尺寸 (以 --stream-width 为基准)。"""
        tw = max(64, int(round(self.args.stream_width * float(scale) / 2.0) * 2))
        th = max(64, int(round(tw * self._h / float(self._w) / 2.0) * 2))
        return tw, th

    def _to_bgr(self, frame, p=None):
        """把 cap.read() 的结果变成 BGR。

        正常情况下 CONVERT_RGB=0 会交回原始 YUV(NV16: w*h*2 字节),
        这里自己按 BT.709 + limited 转, 并且**直接在 YUV 域缩到目标尺寸**
        (后面反正要缩小, 能省掉一大半浮点运算)。
        若某些 OpenCV 版本忽略该属性, 退回到它已转好的 BGR(会有 full-range
        偏色, 会提示一次)。
        """
        self._pre_scaled = False
        wh = self._w * self._h
        n = frame.size
        if frame.ndim == 3 and frame.shape[2] == 3:
            if not self._raw_warned:
                print("[opencv] 警告: 拿不到原始 YUV 缓冲, 回退到 OpenCV 自带转换"
                      " (颜色会偏灰/偏绿)。可尝试 --fourcc NV12", file=sys.stderr)
                self._raw_warned = True
            return frame
        buf = frame.reshape(-1)
        if n == wh * 3:
            return buf.reshape(self._h, self._w, 3)
        if n == wh * 2:
            fmt = "NV16"
        elif n == wh * 3 // 2:
            fmt = "NV12"
        else:
            return None

        # 旋转时目标尺寸会变, 那种情况不做预缩放(少见, 慢一点没关系)
        target = None
        if p is not None and int(p["rotate"]) == 0:
            t = self._target_size(p["scale"])
            if t != (self._w, self._h):
                target = t
                self._pre_scaled = True

        nt = self._conv_threads
        out = None
        is422 = fmt in ("NV16", "YUYV", "UYVY", "YUY2")

        if target is None:
            # 尺寸不变: 直接拿原始缓冲交给 C 版, 零拷贝
            out = yuv_to_bgr_c(buf, self._w, self._h, fmt=fmt,
                               matrix=self.args.yuv_matrix,
                               rng=self.args.yuv_range,
                               swap_uv=self.args.swap_uv, nthreads=nt)
        elif is422:
            # 要缩小时先在 YUV 域缩(数据量小得多), 把 Y/UV 拼进一块连续缓冲 ,
            # 再交给 C 版 —— C 函数要求 [Y][UV] 连续。
            tw, th = target
            y = buf[:wh].reshape(self._h, self._w)
            c = buf[wh:wh * 2].reshape(self._h, self._w // 2, 2)
            ys = cv2.resize(y, (tw, th), interpolation=cv2.INTER_AREA)
            cs = cv2.resize(c, (max(1, tw // 2), th),
                            interpolation=cv2.INTER_AREA)
            need = tw * th
            if self._stage is None or self._stage.size != need * 2:
                self._stage = np.empty(need * 2, np.uint8)
            self._stage[:need] = ys.reshape(-1)
            self._stage[need:] = cs.reshape(-1)
            out = yuv_to_bgr_c(self._stage, tw, th, fmt="NV16",
                               matrix=self.args.yuv_matrix,
                               rng=self.args.yuv_range,
                               swap_uv=self.args.swap_uv, nthreads=nt)

        if out is None:                       # C 库不可用时退回 numpy 版
            out = yuv_to_bgr(buf, self._w, self._h, fmt=fmt,
                             matrix=self.args.yuv_matrix,
                             rng=self.args.yuv_range,
                             swap_uv=self.args.swap_uv,
                             target=target)
        return out

    def _process(self, frame, p):
        """几何变换 -> 缩放 -> 颜色处理。放到缩放之后做颜色, 省 CPU。"""
        rot = int(p["rotate"])
        if rot == 90:
            frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
            self._pre_scaled = False
        elif rot == 180:
            frame = cv2.rotate(frame, cv2.ROTATE_180)
        elif rot == 270:
            frame = cv2.rotate(frame, cv2.ROTATE_90_COUNTERCLOCKWISE)
            self._pre_scaled = False

        if p["mirror"] and p["flipv"]:
            frame = cv2.flip(frame, -1)
        elif p["mirror"]:
            frame = cv2.flip(frame, 1)
        elif p["flipv"]:
            frame = cv2.flip(frame, 0)

        # 缩放: 以 --stream-width 为基准; _to_bgr 已经缩好的就跳过
        if not getattr(self, "_pre_scaled", False):
            scale = float(p["scale"])
            tw = max(64, int(round(self.args.stream_width * scale / 2) * 2))
            th = max(64, int(round(tw * frame.shape[0] / float(frame.shape[1]) / 2) * 2))
            if tw != frame.shape[1]:
                interp = cv2.INTER_AREA if tw < frame.shape[1] else cv2.INTER_LINEAR
                frame = cv2.resize(frame, (tw, th), interpolation=interp)

        # 饱和度 / 色相
        sat, hue = float(p["saturation"]), float(p["hue"])
        if abs(sat - 1.0) > 1e-3 or abs(hue) > 1e-3:
            hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
            if abs(hue) > 1e-3:
                # OpenCV H 通道 0..179 对应 0..358 度
                shift = int(round(hue / 2.0))
                hsv[:, :, 0] = (hsv[:, :, 0].astype(np.int16) + shift) % 180
            if abs(sat - 1.0) > 1e-3:
                hsv[:, :, 1] = np.clip(
                    hsv[:, :, 1].astype(np.float32) * sat, 0, 255).astype(np.uint8)
            frame = cv2.cvtColor(hsv, cv2.COLOR_HSV2BGR)

        # 对比度 / 亮度
        con, bri = float(p["contrast"]), float(p["brightness"])
        if abs(con - 1.0) > 1e-3 or abs(bri) > 1e-3:
            frame = cv2.convertScaleAbs(frame, alpha=con, beta=bri)

        # 伽马
        gam = float(p["gamma"])
        if abs(gam - 1.0) > 1e-3:
            frame = cv2.LUT(frame, self.params.gamma_lut(gam))

        return frame

    def _fallback_loop(self):
        """cv2 不可用时: 发布一张“无信号”提示图, 保持服务可用。"""
        while not self.stop_flag.is_set():
            self.hub.publish(self._placeholder("OpenCV 不可用, 请用 --backend gst"))
            time.sleep(1)

    @staticmethod
    def _placeholder(text):
        if not HAVE_CV2:
            return None
        img = np.zeros((360, 640, 3), dtype=np.uint8)
        cv2.putText(img, text, (20, 180), cv2.FONT_HERSHEY_SIMPLEX,
                    0.8, (0, 0, 255), 2, cv2.LINE_AA)
        ok, buf = cv2.imencode(".jpg", img)
        return buf.tobytes() if ok else None


# ============================================================================
#  采集后端 1c: cv2/PIL 内置测试图案 (最后兜底, 仅在没有 GStreamer 时用)
# ============================================================================
class PilTestCapture(OpenCVCapture):
    name = "test"

    def run(self):
        w, h = self.args.width, self.args.height
        self.hub.publish(None, {"backend": self.name, "device": "internal-test",
                                "width": w, "height": h})
        t0 = time.time()
        while not self.stop_flag.is_set():
            p = self.params.get()
            t = time.time() - t0
            jpeg = None
            if HAVE_CV2:
                frame = self._process(self._make_frame(w, h, t), p)
                ok, buf = cv2.imencode(
                    ".jpg", frame,
                    [int(cv2.IMWRITE_JPEG_QUALITY), int(p["quality"])])
                jpeg = buf.tobytes() if ok else None
            else:
                jpeg = _test_frame_pil(w, h, t, p["quality"])
            if jpeg:
                self.hub.publish(jpeg)
            time.sleep(max(0.0, 1.0 / max(1.0, float(p["fps"])) - 0.004))

    @staticmethod
    def _make_frame(w, h, t):
        """彩条 + 滚动亮条 + 时钟, 便于一眼看出是否卡帧/延迟。"""
        bars = np.zeros((h, w, 3), dtype=np.uint8)
        colors = [(255, 255, 255), (0, 255, 255), (255, 255, 0), (0, 255, 0),
                  (255, 0, 255), (0, 0, 255), (255, 0, 0), (40, 40, 40)]
        bw = max(1, w // len(colors))
        for i, c in enumerate(colors):
            bars[:, i * bw:(i + 1) * bw] = c
        x = int((t * 200) % w)
        if x > 0:
            bars[:, max(0, x - 40):x] = 255
        s1 = max(0.6, h / 900.0)
        s2 = max(0.8, h / 700.0)
        cv2.putText(bars, time.strftime("%Y-%m-%d %H:%M:%S") + "  t=%.1fs" % t,
                    (20, h - 30), cv2.FONT_HERSHEY_SIMPLEX, s1,
                    (0, 0, 0), 2, cv2.LINE_AA)
        cv2.putText(bars, "FPGA-MIPI TEST PATTERN", (20, int(h * 0.12)),
                    cv2.FONT_HERSHEY_SIMPLEX, s2, (0, 0, 0), 2, cv2.LINE_AA)
        return bars


# ============================================================================
#  采集后端 1b: GStreamer 原生管线 (PyGObject) —— ★ 本板首选
#
#  与下面 "gst" 后端的区别:
#    这里用 Gst.parse_launch 建管线, 画面参数直接改 GStreamer 元素的属性,
#    改完立即生效, 不用重启推流、不断流。
#      亮度/对比度/饱和度/色相 -> videobalance
#      伽马                    -> gamma
#      镜像/翻转/旋转          -> videoflip
#      输出缩放                -> videoscale + capsfilter
#      帧率上限                -> videorate + capsfilter
#      JPEG 质量               -> jpegenc
# ============================================================================
class GstLiveCapture(threading.Thread):
    name = "gstlive"

    # GstVideo.VideoFlipMethod: 0=identity 1=90R 2=180 3=90L 4=水平镜像 5=垂直翻转
    FLIP_IDENTITY, FLIP_90R, FLIP_180, FLIP_90L, FLIP_HORIZ, FLIP_VERT = 0, 1, 2, 3, 4, 5

    def __init__(self, hub, params, args):
        super().__init__(daemon=True)
        self.hub = hub
        self.params = params
        self.args = args
        self.stop_flag = threading.Event()
        self._lock = threading.Lock()
        self._pipe = None
        self._applied = {}

    # -------- 子类可覆盖: 数据源 --------
    def source_desc(self):
        return ("v4l2src device=%s ! video/x-raw,width=%d,height=%d"
                % (self.args.device, self.args.width, self.args.height))

    # -------- 管线 --------
    def _scaled_size(self, scale):
        w = max(64, int(round(self.args.stream_width * float(scale) / 2.0) * 2))
        h = max(64, int(round(w * self.args.height / float(self.args.width) / 2.0) * 2))
        return w, h

    # 本工程 FPGA 链路固定输出 1080p60, 所以"上限 >= 60"实际就等于不限速。
    SRC_FPS = 60

    def _fps_caps(self, p):
        """帧率上限对应的 caps。

        注意 videorate 的语义是**重采样**而不是限速: 如果把 caps 设成比源更高的
        帧率, 它会靠**复制帧**来凑数 —— 推流帧率看着翻倍了, 内容却一帧没多,
        还白吃 CPU。所以 fps >= 源帧率时改成"只降不升":
        用一个宽松的区间 caps + drop-only, 让 60fps 原样通过。
        """
        f = int(max(1, p["fps"]))
        if f >= self.SRC_FPS:
            return "video/x-raw,framerate=[0/1,%d/1]" % f
        return "video/x-raw,framerate=%d/1" % f

    def _desc(self, p):
        sw, sh = self._scaled_size(p["scale"])
        return (
            "%s ! "
            # queue 很关键: 让采集与后面的缩放/编码跑在不同线程,
            # 管线吞吐从"串行相加"变成"并行取最大" (实测 29.3 -> 41.5 fps)
            "queue max-size-buffers=4 leaky=downstream ! "
            # drop-only=true: 只允许丢帧, 绝不允许复制帧 (见 _fps_caps 注释)
            "videorate name=rate drop-only=true ! "
            "capsfilter name=frate caps=%s ! "
            "videoconvert ! videoscale ! "
            "capsfilter name=scaler caps=video/x-raw,width=%d,height=%d ! "
            "videoconvert ! "
            "videobalance name=bal ! gamma name=gam ! "
            "videoflip name=flip method=none ! "
            "jpegenc name=enc quality=%d ! "
            "appsink name=sink max-buffers=3 drop=true sync=false"
            % (self.source_desc(), self._fps_caps(p), sw, sh, int(p["quality"]))
        )

    @staticmethod
    def _flip_method(p):
        rot = int(p["rotate"])
        if rot == 90:
            return GstLiveCapture.FLIP_90R
        if rot == 180:
            return GstLiveCapture.FLIP_180
        if rot == 270:
            return GstLiveCapture.FLIP_90L
        m, v = bool(p["mirror"]), bool(p["flipv"])
        if m and v:
            return GstLiveCapture.FLIP_180      # 同 cv2.flip(-1)
        if m:
            return GstLiveCapture.FLIP_HORIZ
        if v:
            return GstLiveCapture.FLIP_VERT
        return GstLiveCapture.FLIP_IDENTITY

    # -------- 主循环 --------
    def run(self):
        if not HAVE_GST_PY:
            print("[%s] 没有 GStreamer Python 绑定: %s" % (self.name, _GST_PY_ERR),
                  file=sys.stderr)
            return
        while not self.stop_flag.is_set():
            try:
                self._run_once()
            except Exception as e:
                print("[%s] %s" % (self.name, e), file=sys.stderr)
            time.sleep(1)

    def _run_once(self):
        p = self.params.get()
        desc = self._desc(p)
        print("[%s] %s" % (self.name, desc))
        pipe = Gst.parse_launch(desc)
        sink = pipe.get_by_name("sink")
        sink.connect("new-sample", self._on_sample)

        self.hub.publish(None, {"backend": self.name, "device": self.args.device,
                                "width": self.args.width, "height": self.args.height})
        with self._lock:
            self._pipe = pipe
            self._applied = {"scale": p["scale"], "fps": p["fps"]}

        pipe.set_state(Gst.State.PLAYING)
        bus = pipe.get_bus()
        try:
            while not self.stop_flag.is_set():
                msg = bus.timed_pop_filtered(
                    200 * Gst.MSECOND,
                    Gst.MessageType.ERROR | Gst.MessageType.EOS)
                if msg is None:
                    continue
                if msg.type == Gst.MessageType.ERROR:
                    err, dbg = msg.parse_error()
                    print("[%s] 管线错误: %s (%s)" % (self.name, err.message, dbg),
                          file=sys.stderr)
                break
        finally:
            pipe.set_state(Gst.State.NULL)
            with self._lock:
                self._pipe = None
        time.sleep(0.3)

    def _on_sample(self, sink):
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.OK
        buf = sample.get_buffer()
        ok, mi = buf.map(Gst.MapFlags.READ)
        if ok:
            try:
                self.hub.publish(bytes(mi.data))
            finally:
                buf.unmap(mi)
        return Gst.FlowReturn.OK

    # -------- 参数在线下发 --------
    def apply(self):
        if not HAVE_GST_PY:
            return
        with self._lock:
            pipe = self._pipe
            applied = dict(self._applied)
        if pipe is None:
            return
        p = self.params.get()
        try:
            bal = pipe.get_by_name("bal")
            if bal is not None:
                self._set(bal, "brightness", float(p["brightness"]) / 100.0)
                self._set(bal, "contrast", float(p["contrast"]))
                self._set(bal, "saturation", float(p["saturation"]))
                self._set(bal, "hue", float(p["hue"]) / 180.0)

            gam = pipe.get_by_name("gam")
            if gam is not None:
                self._set(gam, "gamma", float(p["gamma"]))

            fl = pipe.get_by_name("flip")
            if fl is not None:
                fl.set_property("method", self._flip_method(p))

            enc = pipe.get_by_name("enc")
            if enc is not None:
                self._set(enc, "quality", int(p["quality"]))

            # 缩放 / 帧率需要重新协商 caps
            if applied.get("scale") != p["scale"]:
                sw, sh = self._scaled_size(p["scale"])
                sc = pipe.get_by_name("scaler")
                if sc is not None:
                    sc.set_property("caps", Gst.Caps.from_string(
                        "video/x-raw,width=%d,height=%d" % (sw, sh)))
                applied["scale"] = p["scale"]
            if applied.get("fps") != p["fps"]:
                fr = pipe.get_by_name("frate")
                if fr is not None:
                    fr.set_property("caps",
                                    Gst.Caps.from_string(self._fps_caps(p)))
                applied["fps"] = p["fps"]

            with self._lock:
                self._applied = applied
        except Exception as e:
            print("[%s] apply 失败: %s" % (self.name, e), file=sys.stderr)

    @staticmethod
    def _set(el, name, value):
        """按元素自身取值范围裁剪后再设, 避免越界抛异常。"""
        pspec = el.find_property(name)
        if pspec is not None:
            lo = getattr(pspec, "minimum", None)
            hi = getattr(pspec, "maximum", None)
            if lo is not None and value < lo:
                value = lo
            if hi is not None and value > hi:
                value = hi
        el.set_property(name, value)


# ============================================================================
#  采集后端 1d: --backend test  —— 不接摄像头也能验证整条推流链路
#    优先用 GStreamer 的 videotestsrc, 没有 gi 时退化到 cv2/PIL 图案
# ============================================================================
class TestCapture(GstLiveCapture):
    name = "test"

    def source_desc(self):
        return ("videotestsrc is-live=true pattern=smpte "
                "! video/x-raw,width=%d,height=%d"
                % (self.args.width, self.args.height))

    def run(self):
        if HAVE_GST_PY:
            GstLiveCapture.run(self)
            return
        print("[test] 无 GStreamer Python 绑定, 退化到 cv2/PIL 测试图案", file=sys.stderr)
        PilTestCapture(self.hub, self.params, self.args).run()


# ============================================================================
#  采集后端 2: gst-launch-1.0 子进程 (没有 gi 时的兜底, 参数走 V4L2 硬件)
# ============================================================================
class GstCapture(threading.Thread):
    name = "gst"

    def __init__(self, hub, params, args):
        super().__init__(daemon=True)
        self.hub = hub
        self.params = params
        self.args = args
        self.stop_flag = threading.Event()
        self.proc = None

    def _build_cmd(self, quality):
        # 用 multipartmux 生成标准 multipart/x-mixed-replace, 再逐个抠出 JPEG
        return [
            "gst-launch-1.0", "-q",
            "v4l2src", "device=%s" % self.args.device,
            "!", "video/x-raw,width=%d,height=%d" % (self.args.width, self.args.height),
            # queue: 让采集与缩放/编码并行 (实测有明显收益)
            "!", "queue", "max-size-buffers=4", "leaky=downstream",
            "!", "videoconvert",
            "!", "videoscale", "add-borders=false",
            "!", "video/x-raw,width=%d" % self.args.stream_width,
            "!", "jpegenc", "quality=%d" % int(quality),
            "!", "multipartmux", "boundary=%s" % BOUNDARY,
            "!", "fdsink", "fd=1",
        ]

    def run(self):
        while not self.stop_flag.is_set():
            q = int(self.params.get()["quality"])
            cmd = self._build_cmd(q)
            print("[gst] %s" % " ".join(cmd))
            # 先把状态信息发布出去, 这样即使 gst 起不来, /api/status 也有内容可看
            self.hub.publish(None, {"backend": self.name,
                                    "device": self.args.device,
                                    "width": self.args.width,
                                    "height": self.args.height})
            try:
                self.proc = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    bufsize=0)
            except Exception as e:
                print("[gst] 启动失败: %s" % e, file=sys.stderr)
                time.sleep(2)
                continue

            try:
                self._parse_stream(self.proc.stdout)
            except Exception as e:
                print("[gst] 读取异常: %s" % e, file=sys.stderr)
            finally:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            time.sleep(1)

    def _parse_stream(self, fp):
        """从 multipart 流里抠出 JPEG 帧。"""
        buf = b""
        head = b"--" + BOUNDARY.encode()
        sep = b"\r\n\r\n"
        while not self.stop_flag.is_set():
            chunk = fp.read(65536)
            if not chunk:
                return
            buf += chunk
            while True:
                i = buf.find(head)
                if i < 0:
                    if len(buf) > 8 << 20:      # 防止无限增长
                        buf = buf[-1 << 20:]
                    break
                j = buf.find(head, i + len(head))
                if j < 0:
                    break
                part = buf[i + len(head):j]
                buf = buf[j:]
                k = part.find(sep)
                if k < 0:
                    continue
                img = part[k + len(sep):]
                if img.endswith(b"\r\n"):
                    img = img[:-2]
                if len(img) > 128 and img[:2] == b"\xff\xd8":
                    self.hub.publish(img)
                    time.sleep(1.0 / max(1.0, float(self.params.get()["fps"])))

    def stop(self):
        self.stop_flag.set()
        if self.proc:
            try:
                self.proc.kill()
            except Exception:
                pass


# ============================================================================
#  V4L2 硬件参数(ISP / 传感器)
# ============================================================================
CTRL_RE = re.compile(
    r"^\s*(\S+)\s+(0x[0-9a-fA-F]+)\s+\((\w+)\)\s*:\s*(.*)$")


def list_v4l2_controls(dev, v4l2ctl="v4l2-ctl"):
    """解析 `v4l2-ctl --list-ctrls`, 返回可写控件列表。"""
    try:
        out = subprocess.run([v4l2ctl, "-d", dev, "--list-ctrls"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return []
    res = []
    for line in out.splitlines():
        m = CTRL_RE.match(line)
        if not m:
            continue
        name, _id, typ, rest = m.groups()
        if typ not in ("int", "int64", "bool", "menu", "bitmask"):
            continue
        item = {"name": name, "type": typ, "id": _id}
        for kv in rest.split():
            if "=" not in kv:
                continue
            k, v = kv.split("=", 1)
            if k in ("min", "max", "step", "default"):
                try:
                    item[k] = int(v)
                except ValueError:
                    item[k] = v
            elif k == "value":
                try:
                    item[k] = int(v)
                except ValueError:
                    item[k] = v
            elif k == "flags":
                item["flags"] = [v]
        # 只留下能滑动的、可写的
        if "min" in item and "max" in item and isinstance(item["min"], int):
            if item.get("max") == item.get("min"):
                continue
            if "inactive" in str(item.get("flags", "")):
                continue
            res.append(item)
    return res


def set_v4l2_control(dev, name, value, v4l2ctl="v4l2-ctl"):
    try:
        p = subprocess.run([v4l2ctl, "-d", dev, "--set-ctrl",
                            "%s=%d" % (name, int(value))],
                           capture_output=True, text=True, timeout=5)
        return p.returncode == 0, (p.stderr or p.stdout).strip()
    except Exception as e:
        return False, str(e)


# ============================================================================
#  FPGA 硬件参数 (I2C 从机 @0x40)
#
#  寄存器映射与 fpga/uisrc/01_rtl/jpeg/jpeg_regfile.v 一一对应。
#  接线: RK 的 I2C9 底板直连 FPGA 的 L18(SCL)/M18(SDA) —— **不需要飞线**。
#  实测 `i2cdetect -y 9` 能看到 0x40 (0x1a 是内核 milianke_mipi 驱动占用的 UU)。
#
#  FPGA 侧是纯从机、不做时钟拉伸; 读寄存器要先写子地址再读 (smbus 约定),
#  所以 /dev/i2c-N 必须用**读写**模式打开 —— 用 'rb' 会报 File not open for writing。
# ============================================================================
FPGA_I2C_SLAVE = 0x0703          # linux/i2c-dev.h 里的 I2C_SLAVE

#  name, addr, min, max, 只读, 说明
FPGA_REGS = [
    ("PP_EN",       0xB0,   0,    1, False, "预处理总使能 (0=直通原图)"),
    ("PP_MODE",     0xB1,   0,    3, False, "0=原图 1=Sobel 2=阈值分割 3=形态学"),
    ("PP_SOBEL_SH", 0xB2,   0,    8, False, "Sobel 幅度右移 (3 -> 满量程)"),
    ("PP_THRESH",   0xB3,   0,  255, False, "二值化阈值"),
    ("PP_MORPH",    0xB4,   0,    1, False, "0=腐蚀(&) 1=膨胀(|)"),
    # ---- 摄像头 / 画质 (0xC0 起) ----
    # 曝光是 20 位, 拆 3 字节; UI 不直接用它们, 而是用 CAM_EXP_MS 物理量
    ("CAM_EXP_L",   0xC0,   0,  255, False, "曝光 SHR0[7:0]"),
    ("CAM_EXP_M",   0xC1,   0,  255, False, "曝光 SHR0[15:8]"),
    ("CAM_EXP_H",   0xC2,   0,   15, False, "曝光 SHR0[19:16]"),
    ("CAM_GAIN",    0xC3,   0,  100, False, "增益 0..100 (0.3dB/step)"),
    ("EV_BIAS",     0xC4,   0,   15, False, "曝光补偿, 8 = 0EV"),
    ("WB_R",        0xC5,   0,  255, False, "白平衡 R 增益 (128=1.0x)"),
    ("WB_B",        0xC6,   0,  255, False, "白平衡 B 增益 (128=1.0x)"),
    ("FPS_DIV",     0xC7,   1,    8, False, "帧率分频 (1=原速)"),
    ("ROI_PCT",     0xC8,  25,  100, False, "ROI 百分比 (100=全画幅)"),
    ("CAM_TRIG",    0xC9,   0,  255, False, "写任意值 -> 触发一次参数下发"),
    # ---- 分辨率模式 (V21 新增, 地址 0xE0) ----
    #   配套 FPGA system_top.v 的 S_res_mode 模式表。写下去 FPGA 会把
    #   ui_image_correction 的裁剪边界从 480 组放到 960 组、VTC 几何切到 4K,
    #   并产生一个复位窗口重新对齐 ==> RK 侧必须同时改采集格式 (用 /api/mode)。
    ("RES_MODE",    0xE0,   0,    2, False, "分辨率模式 (0=1080p60 1=4K30 2=4K25)"),
]
#  name, addr, 字节数, 说明
FPGA_STATUS = [
    ("FRAME_CNT",   0xB8,   4, "已接收帧数 (32 位小端)"),
    ("HEARTBEAT",   0xBC,   1, "心跳 (每 256 个 25MHz 周期 +1)"),
    ("VER",         0xA9,   2, "版本号 (低字节在前)"),
    ("CAM_WR_CNT",  0xD0,   2, "摄像头寄存器写成功次数"),
    ("CAM_BUSY",    0xD2,   1, "摄像头参数正在下发"),
    ("CAM_ID",      0xD3,   1, "参数区存在标志 (0xA5)"),
]

# ============================================================================
#  分辨率 / 帧率 模式表  —— 网页两个下拉框的单一事实来源
#
#  限制关系有三处, 缺一不可:
#
#  1) FPGA 的 S_res_mode 模式表 (system_top.v, V21):
#         0 -> 1920x1080, VTC 2200x1125 => 59.6 fps
#         1 -> 3840x2160, VTC 2060x2387 => 30.0 fps
#     切模式 = 写 regfile 0xE0 (RES_MODE)。写下去 FPGA 会同时改裁剪边界与
#     VTC 几何并产生一个复位窗口, 所以 **RK 侧的采集格式必须一起改**。
#
#  2) 帧率 = 模式基准帧率 / FPS_DIV (0xC7, 1..8)。基准 60 (1080p) 或 30 (4K)。
#     注意 "/api/fpga 的 fps 物理量" 是按 60 基换算的, 4K 下不要用它, 用 /api/mode。
#
#  3) 链路带宽: V22 的 byte_clk=125MHz -> lane 1000Mbps -> 4 lane = 500 MB/s。
#     YUV422 每像素 2 字节, 有效载荷 = 宽 x 高 x 帧率 x 2:
#         1080p60 = 248.8 MB/s (49.8%)  OK
#         4K30    = 497.7 MB/s (99.5%)  跑不动 (每行还要留消隐间隙)
#     想跑真 4K30 必须先把 FPGA 提到 1200Mbps (需要先做时序收敛, 见 V22 注释)。
# ============================================================================
LINK_BYTES_PER_SEC = 4 * 1000e6 / 8.0      # 4 lane x 1000 Mbps / 8 bit = 500 MB/s
LINK_USABLE_RATIO  = 0.85                  # 超过这个比例就判为"超带宽"

# ⚠ FPS_DIV (0xC7) 目前是**死寄存器**: jpeg_regfile -> cfg_ctrl_top -> system_top.v
#   的 S_fps_div 一路都送出来了, 但**没有任何模块消费它**。实测 FPS_DIV=2 之后
#   帧率仍然是 59.6 fps ⇒ 跳帧降帧率在当前 RTL 里不生效。
#   要把降帧档变真, 必须先补 RTL (在 VTC 读侧按 fps_div 丢帧), 再把这里改成 True。
FPS_DIV_IMPLEMENTED = False

# ⚠ 切换分辨率：已经实测可反复切换。
#  1080p60 <-> 4K25（RES_MODE 0<->2）加上整条 media pipeline 重建 + 80ms 协同复位窗，
#  反复切十几次不撕裂、不起死。所以这里放开了；单帧不匹配的瞬间最多黑一下。
MODE_SWITCH_SAFE = True


def _mk_mode(mid, w, h, fps, res_mode, fps_div):
    load = w * h * fps * 2.0
    return {
        "id": mid,
        "label": "%dx%d @ %g fps" % (w, h, fps),
        "w": w, "h": h, "fps": fps,
        "res_mode": res_mode, "fps_div": fps_div,
        "load_mb_s": round(load / 1e6, 1),
        "load_pct": round(100.0 * load / LINK_BYTES_PER_SEC, 1),
        "ok": (load / LINK_BYTES_PER_SEC) <= LINK_USABLE_RATIO,
        # impl = FPGA 当前 RTL 是否真能做出这个帧率
        "impl": FPS_DIV_IMPLEMENTED or (fps_div == 1),
    }


# 当前 V22 bit 实际支持的全部组合 (改 FPGA 模式表后在这里同步)
MODES = [
    _mk_mode("1080p60", 1920, 1080, 60, 0, 1),
    _mk_mode("1080p30", 1920, 1080, 30, 0, 2),
    _mk_mode("1080p15", 1920, 1080, 15, 0, 4),
    _mk_mode("4k25",    3840, 2160, 25, 2, 1),
    _mk_mode("4k15",    3840, 2160, 15, 1, 2),
    _mk_mode("4k10",    3840, 2160, 10, 1, 3),
    _mk_mode("4k30",    3840, 2160, 30, 1, 1),
    _mk_mode("720p90",  1280,  720, 90, 3, 1),
]
# 720p / 90fps 还没有进 FPGA 的裁剪与 VTC 模式表（RES_MODE 目前只有 0=1080p / 2=4K），
# 90fps 也要重新收敛时序 —— 所以选项先摆出来，但明确标“未实现”，点应用会被拦下。
for _m in MODES:
    if _m["id"].startswith("720p"):
        _m["impl"] = False
        _m["note"] = "FPGA RTL 未实现 720p / 90fps"
MODES_BY_ID = {m["id"]: m for m in MODES}


def mode_resolutions():
    """按分辨率分组 —— 前端"选分辨率 -> 只留该分辨率的帧率"就是靠它。"""
    out = {}
    for m in MODES:
        key = "%dx%d" % (m["w"], m["h"])
        if key not in out:
            out[key] = {"key": key, "w": m["w"], "h": m["h"], "modes": []}
        out[key]["modes"].append(m)
    return list(out.values())


def current_mode(regs):
    """从回读的寄存器推当前模式; 找不到就返回 None。"""
    try:
        rm = int(regs.get("RES_MODE", 0))
        fd = int(regs.get("FPS_DIV", 1))
    except Exception:
        return None
    for m in MODES:
        if m["res_mode"] == rm and m["fps_div"] == fd:
            return m
    return None


def mode_base_fps(regs):
    """当前分辨率模式的基准帧率 (给 cam_phys 换算用)。"""
    try:
        rm = int(regs.get("RES_MODE", 0))
    except Exception:
        return 60.0
    return {0: 60.0, 1: 30.0, 2: 25.0}.get(rm, 60.0)


def v4l2_set_fmt(device, w, h, fourcc="NV16", v4l2ctl="v4l2-ctl"):
    """用 v4l2-ctl 设采集节点格式。

    切分辨率时必须做 —— 否则 rkcif 还按旧尺寸协商, 画面会被当成另一张图解析。
    返回 (ok, 消息)。
    """
    try:
        p = subprocess.run(
            [v4l2ctl, "-d", device,
             "--set-fmt-video=width=%d,height=%d,pixelformat=%s" % (w, h, fourcc)],
            capture_output=True, text=True, timeout=10)
        out = (p.stdout or p.stderr or "").strip().replace("\n", " ")
        return p.returncode == 0, "%dx%d %s: %s" % (w, h, fourcc, out or "ok")
    except Exception as e:
        return False, "v4l2-ctl 失败: %s: %s" % (type(e).__name__, e)


# ============================================================================
#  切分辨率时改 RK 侧整条 media pipeline
#
#  ⚠ 为什么必须用 media-ctl 从 **sensor subdev** 设起:
#    rkcif 是"上游 subdev 驱动下游"的模型。只跑
#      v4l2-ctl -d /dev/video22 --set-fmt-video width=3840,height=2160
#    会返回成功, 但驱动立刻把尺寸从上游 subdev 拉回来 => 实际还是 1920x1080
#    (实测 --get-fmt-video 一直显示 1920/1080)。
#    正确做法是先把 sensor 那一环设成目标尺寸, 再让它往下游传播。
#
#  实体/链路 (实测 /dev/media2):
#    m02_back_FPGA-MIPI 9-001a  (/dev/v4l-subdev4)  pad0 Source  <- 源头
#    rockchip-csi2-dphy3         (/dev/v4l-subdev3)  pad0 Sink / pad1 Source
#    rockchip-mipi-csi2          (/dev/v4l-subdev2)  pad0 Sink
#    stream_cif_mipi_id0         (/dev/video22)      pad0 Sink
#  sensor 驱动的 milianke_set_fmt 只按 (w,h) 做**精确匹配**, 3840x2160 会命中
#  表里第一个条目 = 4K25 (milianke_mipi.c 里 4K25 排在 4K30 前面)。
# ============================================================================
MEDIA_DEV = "/dev/media2"
MEDIA_FMT_PADS = [
    ('"m02_back_FPGA-MIPI 9-001a"', 0),
    ('"rockchip-csi2-dphy3"',        0),
    ('"rockchip-csi2-dphy3"',        1),
    ('"rockchip-mipi-csi2"',         0),
]


def pipeline_set_fmt(w, h, media_dev=MEDIA_DEV, media_ctl="media-ctl"):
    """把目标尺寸灌进整条 pipeline, 从 sensor subdev 开始。

    返回 [(spec, ok, err), ...]
    """
    out = []
    fmt = "fmt:YUYV8_2X8/%dx%d" % (w, h)
    for ent, pad in MEDIA_FMT_PADS:
        spec = "%s:%d[%s]" % (ent, pad, fmt)
        try:
            p = subprocess.run([media_ctl, "-d", media_dev, "--set-v4l2", spec],
                               capture_output=True, text=True, timeout=10)
            err = (p.stderr or "").strip().replace("\n", " ")[:140]
            out.append((spec, p.returncode == 0, err))
        except Exception as e:
            out.append((spec, False, "%s: %s" % (type(e).__name__, e)))
    return out


# ============================================================================
#  IMX415 曝光/增益换算 (给网页用物理量, 而不是裸寄存器值)
#
#  曝光行数 = VMAX - SHR0
#  VMAX    = 0x0008EB = 2283  行  (ui_imx415_reg.v 的 0x3024/25/26)
#  行周期  = HMAX / 像素时钟 = 542 / 74.25MHz = 7.3us
#  => 曝光时间 = (VMAX - SHR0) * 7.3us
#     SHR0 = 8    -> 16.6ms (初始化表默认, 最亮)
#     SHR0 = 2275 -> 0.058ms (最短)
#  SHR0 越大曝光越短, 别搞反。
#
#  增益: 0x3090 取值 0..100, 每步 0.3dB (0x64=100 -> 30dB)
# ============================================================================
# V24(2026-10-16): VMAX / 行周期跟传感器读出模式走。
#   曝光行数 = VMAX - SHR0, VMAX 用错曝光就差一倍。
#     1080p (2x2 binning): VMAX=2283, 行周期 542/74.25MHz = 7.30us
#     4K    (all-pixel)  : VMAX=4503, 行周期 533/74.25MHz = 7.18us
#   （对应 ui_imx415_reg.v 的 0x3024/25 与 0x3028, 由 RES_MODE 选表）
CAM_VMAX_1080      = 2283
CAM_T_LINE_US_1080 = 7.30
CAM_VMAX_4K        = 4503
CAM_T_LINE_US_4K   = 7.18

# 兼容旧引用 (默认按 1080p)
CAM_VMAX      = CAM_VMAX_1080
CAM_T_LINE_US = CAM_T_LINE_US_1080


def cam_mode_params(regs):
    """按 FPGA 的 RES_MODE 返回 (VMAX, 行周期us)。RES_MODE: 0=1080p60, 1=4K30, 2=4K25"""
    try:
        rm = int(regs.get("RES_MODE", 0) or 0)
    except Exception:
        rm = 0
    if rm in (1, 2):
        return CAM_VMAX_4K, CAM_T_LINE_US_4K
    return CAM_VMAX_1080, CAM_T_LINE_US_1080


def cam_shr0_from_ms(ms, vmax=None, t_line=None):
    """曝光时间(ms) -> SHR0 寄存器值"""
    vmax = CAM_VMAX if vmax is None else int(vmax)
    t_line = CAM_T_LINE_US if t_line is None else float(t_line)
    rows = int(round(float(ms) * 1000.0 / t_line))
    rows = max(1, min(rows, vmax - 1))
    return vmax - rows


def cam_ms_from_shr0(shr0, vmax=None, t_line=None):
    """SHR0 -> 曝光时间(ms)"""
    vmax = CAM_VMAX if vmax is None else int(vmax)
    t_line = CAM_T_LINE_US if t_line is None else float(t_line)
    rows = max(1, vmax - int(shr0))
    return rows * t_line / 1000.0


def cam_phys(regs, status=None):
    """把寄存器值换算成给 UI 用的物理量

    ⚠ 先看 CAM_ID (0xD3) 是不是 0xA5: 烧的 bit 流里没有参数区时, 0xC0~0xC9
      读回来全是 0, 而 0 对 EV_BIAS/WB_R 恰好是“合法值”, 单看值分不出来
      (之前就出现过 UI 把 EV 显示成 -8 的情况)。没有参数区就全部用默认值。
    """
    status = status or {}
    has_area = (status.get("CAM_ID") == 0xA5)

    def pick(name, lo, hi, dflt):
        if not has_area:
            return dflt
        try:
            v = int(regs.get(name, dflt))
        except Exception:
            return dflt
        return v if lo <= v <= hi else dflt

    try:
        shr0 = (pick("CAM_EXP_L", 0, 255, 0) |
                (pick("CAM_EXP_M", 0, 255, 0) << 8) |
                (pick("CAM_EXP_H", 0, 15, 0) << 16))
        # V24: 曝光换算要跟传感器读出模式走 (4K 的 VMAX 是 4503, 不是 2283)
        vmax, t_line = cam_mode_params(regs)
        # SHR0 = 0 表示“保持初始化表的值”, 按默认 8 报
        if not (1 <= shr0 <= vmax - 1):
            shr0 = 8
        ms = cam_ms_from_shr0(shr0, vmax, t_line)

        # CAM_GAIN = 0 表示“保持初始化表的值” (0x30 -> 14.4dB)
        gain = pick("CAM_GAIN", 1, 100, 0)
        gain_db = (gain * 0.3) if gain else 14.4

        return {
            "cam_exp_ms":  round(ms, 2),
            "cam_gain_db": round(gain_db, 1),
            "ev":          pick("EV_BIAS", 0, 15, 8) - 8,
            # 基准帧率跟分辨率模式走: 1080p=60, 4K=30 (V21 模式表)
            "fps":         round(mode_base_fps(regs) / pick("FPS_DIV", 1, 8, 1), 1),
            "res_mode":    pick("RES_MODE", 0, 2, 0),
            "wb_r_pct":    round(pick("WB_R", 1, 255, 128) / 1.28, 0),
            "wb_b_pct":    round(pick("WB_B", 1, 255, 128) / 1.28, 0),
            "roi_pct":     pick("ROI_PCT", 25, 100, 100),
        }
    except Exception:
        return {}

FPGA_PRESETS = {
    "off":    {"PP_EN": 0},
    "orig":   {"PP_EN": 1, "PP_MODE": 0},
    "sobel":  {"PP_EN": 1, "PP_MODE": 1},
    "thresh": {"PP_EN": 1, "PP_MODE": 2},
    "morph":  {"PP_EN": 1, "PP_MODE": 3},
}


def _fpga_pp_off(fpga):
    """关掉 FPGA 预处理（PP_EN=0），返回一句给页面看的描述。

    预处理（Sobel/阈值/形态学）是给人看的艺术效果，AI 拿那种画面去检测
    只会瞎猜，所以一旦要用 AI 标注就自动把预处理关掉。
    """
    if fpga is None:
        return "跳过(FPGA I2C 未启用)"
    try:
        ok, msg = fpga.apply({"PP_EN": 0})
        return "已关闭" if ok else ("失败: %s" % msg)
    except Exception as e:                                   # noqa: BLE001
        return "失败: %s" % e


class FpgaI2C(object):
    """FPGA 寄存器堆的 I2C 访问。

    每次读写都开关一次 fd —— I2C 才 100kHz, 这点开销可以忽略,
    换来的是不会在推流长时间运行时持有陈旧 fd。
    """

    def __init__(self, bus=9, addr=0x40):
        self.bus = int(bus)
        self.addr = int(addr)
        self.path = "/dev/i2c-%d" % self.bus

    def available(self):
        return os.path.exists(self.path)

    def _open(self):
        import fcntl
        f = open(self.path, "r+b", buffering=0)
        try:
            fcntl.ioctl(f, FPGA_I2C_SLAVE, self.addr)
        except Exception:
            f.close()
            raise
        return f

    def read(self, reg):
        f = self._open()
        try:
            f.write(bytes([reg & 0xFF]))   # 先写子地址
            d = f.read(1)
            if not d:
                raise IOError("读 0x%02X 无数据" % reg)
            return d[0]
        finally:
            f.close()

    def read_multi(self, reg, n):
        """连读 n 字节 (FPGA 侧指针自动递增)。"""
        f = self._open()
        try:
            f.write(bytes([reg & 0xFF]))
            d = f.read(n)
            if len(d) != n:
                raise IOError("读 0x%02X x%d 只拿到 %d 字节" % (reg, n, len(d)))
            return list(d)
        finally:
            f.close()

    def write(self, reg, val):
        f = self._open()
        try:
            f.write(bytes([reg & 0xFF, val & 0xFF]))
        finally:
            f.close()

    def snapshot(self):
        """读回全部可写寄存器 + 只读状态。返回 (ok, dict)。"""
        out = {"bus": self.bus, "addr": self.addr, "regs": {}, "status": {}}
        try:
            for name, a, _lo, _hi, _ro, _d in FPGA_REGS:
                out["regs"][name] = self.read(a)
            for name, a, n, _d in FPGA_STATUS:
                if n == 1:
                    out["status"][name] = self.read(a)
                else:
                    out["status"][name] = int.from_bytes(
                        bytes(self.read_multi(a, n)), "little")
            out["phys"] = cam_phys(out["regs"], out["status"])
            out["ok"] = True
        except Exception as e:
            out["ok"] = False
            out["error"] = "%s: %s" % (type(e).__name__, e)
        return out["ok"], out

    def apply(self, patch):
        """写若干个寄存器; 键可以是寄存器名, 也可以是 'preset'。

        越界的值直接夹到合法范围 (前端滑块应该已经限制了, 这里兜底)。
        返回 (ok, message)。

        ⚠ 先把 preset 展开成普通 {名: 值} 字典再统一处理 ——
          早期版本直接 writes.extend(pre.items()), 结果混进了 2 元组
          (而普通路径是 3 元组 (name, addr, value)), 解包时 ValueError
          被 except 吞掉变成 HTTP 500。
        """
        flat = {}
        for k, v in (patch or {}).items():
            kl = str(k).strip().lower()
            # ---- 物理量 -> 寄存器 (网页用的是物理量, 更好懂) ----
            if kl in ("cam_exp_ms", "exp_ms"):
                # V24: 曝光换算要跟模式走 —— 4K 的 VMAX=4503/行周期7.18us,
                #      1080p 是 2283/7.30us。用错的话设 16ms 实际只得到 8ms。
                _vm, _tl = ((CAM_VMAX_4K, CAM_T_LINE_US_4K)
                            if int(self.args.height) > 1080
                            else (CAM_VMAX_1080, CAM_T_LINE_US_1080))
                s = cam_shr0_from_ms(v, _vm, _tl)
                flat["CAM_EXP_L"] = s & 0xFF
                flat["CAM_EXP_M"] = (s >> 8) & 0xFF
                flat["CAM_EXP_H"] = (s >> 16) & 0x0F
                continue
            if kl in ("cam_gain_db", "gain_db"):
                flat["CAM_GAIN"] = max(0, min(int(round(float(v) / 0.3)), 100))
                continue
            if kl == "ev":
                flat["EV_BIAS"] = max(0, min(int(round(float(v))) + 8, 15))
                continue
            if kl == "fps":
                n = int(round(60.0 / max(1.0, float(v))))
                flat["FPS_DIV"] = max(1, min(n, 8))
                continue
            # ⚠ 早期漏掉了 roi_pct —— 网页"有效画面"滑块 POST 的就是它,
            #    结果 apply() 在写任何寄存器之前就 return False("未知寄存器"),
            #    整批参数一起被拒。补上。
            if kl == "roi_pct":
                flat["ROI_PCT"] = max(25, min(int(round(float(v))), 100))
                continue
            if kl in ("res_mode", "resolution_mode"):
                flat["RES_MODE"] = max(0, min(int(round(float(v))), 2))
                continue
            if kl == "wb_r_pct":
                flat["WB_R"] = max(0, min(int(round(float(v) * 1.28)), 255))
                continue
            if kl == "wb_b_pct":
                flat["WB_B"] = max(0, min(int(round(float(v) * 1.28)), 255))
                continue
            # ---- 寄存器名 / 预设 ----
            if k == "preset":
                pre = FPGA_PRESETS.get(str(v))
                if pre is None:
                    return False, "未知预设: %s" % v
                flat.update(pre)
            else:
                flat[str(k).strip()] = v

        writes = []
        for name, v in flat.items():
            hit = None
            for rn, ra, lo, hi, ro, _d in FPGA_REGS:
                if name == rn or name.upper() in ("0X%02X" % ra, str(ra)):
                    hit = (rn, ra, lo, hi, ro)
                    break
            if hit is None:
                return False, "未知寄存器: %s" % name
            rn, ra, lo, hi, ro = hit
            if ro:
                return False, "%s 是只读寄存器" % rn
            try:
                iv = int(round(float(v)))
            except (TypeError, ValueError):
                return False, "%s 值非法: %r" % (rn, v)
            writes.append((rn, ra, min(max(iv, lo), hi)))

        if not writes:
            return True, "无变化"
        try:
            for _rn, ra, iv in writes:
                self.write(ra, iv)
        except Exception as e:
            return False, "%s: %s" % (type(e).__name__, e)
        return True, "已写入 %d 个寄存器" % len(writes)


def fpga_meta():
    """给前端用的寄存器元信息 (范围/描述/预设)。"""
    return {
        "writable": [{"name": n, "addr": a, "min": lo, "max": hi, "desc": d}
                     for n, a, lo, hi, _ro, d in FPGA_REGS],
        "readonly": [{"name": n, "addr": a, "bytes": c, "desc": d}
                     for n, a, c, d in FPGA_STATUS],
        "presets": FPGA_PRESETS,
    }


# ============================================================================
#  HTTP 服务
# ============================================================================
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "MipiWebStream/1.0"

    # ---- 由 Server 注入 ----
    hub = None
    params = None
    args = None
    capture = None
    fpga = None

    # ---------- 工具 ----------
    def log_message(self, fmt, *a):
        if self.args.verbose:
            sys.stderr.write("[http] " + (fmt % a) + "\n")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            n = 0
        raw = self.rfile.read(n) if n else b""
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    # ---------- 路由 ----------
    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        try:
            if path in ("/", "/index.html", "/viewer"):
                return self._serve_viewer()
            if path == "/stream":
                return self._serve_stream()
            if path == "/api/params":
                return self._json(self.params.get())
            if path == "/api/status":
                st = self.hub.status()
                st["params"] = self.params.get()
                st["device"] = self.args.device
                st["port"] = self.args.port
                st["python"] = sys.executable
                st["ai"] = AI_OVERLAY.status() if AI_OVERLAY is not None else None
                st["backends"] = {
                    "gi_gst": HAVE_GST_PY,
                    "cv2": HAVE_CV2,
                    "gst_launch": _have_cmd("gst-launch-1.0"),
                }
                return self._json(st)
            if path == "/api/ai":
                if AI_OVERLAY is None:
                    msg = "AI 未启用: 启动时加 --ai"
                    if _AI_IMPORT_ERR:
                        msg += " (导入 ai_overlay 失败: %s)" % _AI_IMPORT_ERR
                    return self._json({"ok": False, "error": msg}, 503)
                return self._json(AI_OVERLAY.status())
            if path == "/api/controls":
                return self._json(list_v4l2_controls(self.args.device,
                                                     self.args.v4l2ctl))
            if path == "/api/fpga":
                if self.fpga is None:
                    return self._json(
                        {"ok": False, "error": "FPGA I2C 未启用 (--fpga-bus -1)"},
                        503)
                _ok, snap = self.fpga.snapshot()
                snap["meta"] = fpga_meta()
                return self._json(snap)
            if path == "/api/modes":
                regs = {}
                if self.fpga is not None:
                    try:
                        _ok, snap = self.fpga.snapshot()
                        regs = snap.get("regs", {}) or {}
                    except Exception:
                        regs = {}
                return self._json({
                    "ok": True,
                    "switch_safe": MODE_SWITCH_SAFE,
                    "fps_div_impl": FPS_DIV_IMPLEMENTED,
                    "link_mb_s": round(LINK_BYTES_PER_SEC / 1e6, 1),
                    "link_note": "4 lane x 1000 Mbps (V22 byte_clk 125MHz)",
                    "usable_ratio": LINK_USABLE_RATIO,
                    "resolutions": mode_resolutions(),
                    "current": current_mode(regs),
                    "regs": {"RES_MODE": regs.get("RES_MODE"),
                             "FPS_DIV": regs.get("FPS_DIV")},
                    "capture": {"width": self.args.width,
                                "height": self.args.height},
                })
            if path in ("/snapshot.jpg", "/snapshot"):
                jpeg, _ = self.hub.snapshot()
                if not jpeg:
                    return self._json({"error": "no frame"}, 503)
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(jpeg)))
                self._cors()
                self.end_headers()
                self.wfile.write(jpeg)
                return
            return self._json({"error": "not found", "path": path}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        try:
            if path == "/api/params":
                body = self._read_json()
                if body.get("reset"):
                    out = self.params.reset()
                else:
                    out = self.params.update(_clamp_params(body))
                # 参数变化后立刻下发到采集管线 (GStreamer 后端无需重启推流)
                cap = Handler.capture
                if cap is not None and hasattr(cap, "apply"):
                    cap.apply()
                return self._json(out)
            if path == "/api/ctrl":
                body = self._read_json()
                name = body.get("name")
                if not name:
                    return self._json({"error": "missing name"}, 400)
                ok, msg = set_v4l2_control(self.args.device, name,
                                           body.get("value", 0),
                                           self.args.v4l2ctl)
                return self._json({"ok": ok, "message": msg},
                                  200 if ok else 500)
            if path == "/api/ai":
                if AI_OVERLAY is None:
                    return self._json({"ok": False, "error": "AI 未启用 (启动时加 --ai)"}, 503)
                out = AI_OVERLAY.apply(self._read_json())
                # 切到 AI 标注（或重新启用 AI）时，自动关掉 FPGA 预处理：
                # Sobel/阈值/形态学是给人看的，AI 拿那种画面去检测只会瞎猜。
                # 只在“真的要用 AI”的时候写，免得用户单纯调参数也被改掉预处理。
                if out.get("active"):
                    out["pp_off"] = _fpga_pp_off(self.fpga)
                return self._json({"ok": True, "ai": out})
            if path == "/api/fpga":
                if self.fpga is None:
                    return self._json(
                        {"ok": False, "error": "FPGA I2C 未启用 (--fpga-bus -1)"},
                        503)
                body = self._read_json()
                wok, msg = self.fpga.apply(body)
                # 写完立刻回读 —— FPGA 侧可能把值夹过, 前端以回读为准
                _ok, snap = self.fpga.snapshot()
                # 打开预处理（PP_EN=1 且真的在做 Sobel/阈值/形态学，即 PP_MODE≠0）时，
                # 自动把 AI 标注切回原图 —— 反过来“切到 AI 标注会自动关预处理”，两边对称。
                # PP_MODE=0（直通原图）不影响 AI，不触发。
                _regs = snap.get("regs") or {}
                if (int(_regs.get("PP_EN", 0)) == 1 and int(_regs.get("PP_MODE", 0)) != 0
                        and AI_OVERLAY is not None and AI_OVERLAY.active):
                    try:
                        AI_OVERLAY.apply({"source": "raw"})
                        snap["ai_off"] = "已切回原图"
                    except Exception as _e:                          # noqa: BLE001
                        snap["ai_off"] = "切换失败: %s" % _e
                snap["write_ok"] = wok
                snap["message"] = msg
                snap["meta"] = fpga_meta()
                return self._json(snap, 200 if (wok and snap.get("ok")) else 500)
            if path == "/api/mode":
                body = self._read_json()
                mid = body.get("id") or body.get("mode")
                if mid is None and body.get("width"):
                    for _m in MODES:
                        if (_m["w"] == int(body["width"]) and
                                _m["h"] == int(body.get("height", 0))):
                            mid = _m["id"]
                            break
                m = MODES_BY_ID.get(str(mid))
                if m is None:
                    return self._json({"ok": False,
                                       "error": "未知模式: %r (可选: %s)"
                                                % (mid, ", ".join(MODES_BY_ID))},
                                      400)
                res = self._apply_mode(m, force=bool(body.get("force")))
                return self._json(res, 200 if res.get("ok") else 500)
            return self._json({"error": "not found", "path": path}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass

    # ---------- 分辨率/帧率切换 ----------
    def _apply_mode(self, mode, force=False):
        """切模式: FPGA 寄存器 -> RK 侧 V4L2 格式 -> 采集线程重开。

        顺序是先改源头 (FPGA) 再改消化端 (RK), 中间会有一瞬不匹配, 可接受。
        """
        log = []
        if not MODE_SWITCH_SAFE and not force:
            return {"ok": False, "log": log,
                    "error": "分辨率切换目前标为不安全: 整条视频通路的协同复位尚未实现, "
                             "切完画面会撕裂并可能把 RX/TX 拖死(需重烧 bit)。"
                             "确实要试请带 \"force\": true。"}
        if not mode["impl"] and not force:
            return {"ok": False, "log": log,
                    "error": "%s 需要跳帧(FPS_DIV=%d), 但当前 FPGA RTL 里 FPS_DIV 是"
                             "死寄存器(无模块消费), 降帧不生效。先补 RTL, "
                             "或带 \"force\": true 只切分辨率(帧率不会变)。"
                             % (mode["label"], mode["fps_div"])}
        if not mode["ok"] and not force:
            return {"ok": False, "log": log,
                    "error": "%s 需要 %.1f MB/s, 占链路 %.1f%% (>%.0f%% 判为跑不动); "
                             "确实要试请带 \"force\": true"
                             % (mode["label"], mode["load_mb_s"], mode["load_pct"],
                                LINK_USABLE_RATIO * 100)}
        if self.fpga is None:
            return {"ok": False, "error": "FPGA I2C 未启用 (--fpga-bus -1)", "log": log}
        try:
            # FPS_DIV 先写; RES_MODE 后写 —— 写它会产生 VTC 复位窗口,
            # 让它作为最后一步, 免得复位后帧率又被改一次。
            self.fpga.write(0xC7, int(mode["fps_div"]))
            self.fpga.write(0xE0, int(mode["res_mode"]))
            log.append("FPGA: FPS_DIV=%d RES_MODE=%d" % (mode["fps_div"], mode["res_mode"]))
        except Exception as e:
            return {"ok": False, "log": log,
                    "error": "FPGA 写入失败: %s: %s" % (type(e).__name__, e)}

        # ---- RK 侧: 整条 media pipeline 改成新尺寸 ----
        #   必须改! 只写 FPGA 寄存器的话 rkcif 还按旧尺寸收, 画面是一团错位。
        #   也必须从 sensor subdev 设起 (见 pipeline_set_fmt 的注释)。
        #   等一小会儿让 FPGA 的复位窗(80ms)过去, 免得刚设完就被切一刀。
        time.sleep(0.25)
        try:
            res = pipeline_set_fmt(int(mode["w"]), int(mode["h"]))
            bad = [(s, e) for (s, ok, e) in res if not ok]
            log.append("media-ctl 设 %dx%d: %d/%d pad 成功"
                       % (mode["w"], mode["h"], len(res) - len(bad), len(res)))
            for s, e in bad:
                log.append("  ✗ %s  %s" % (s, e))
        except Exception as e:
            log.append("media-ctl 异常: %s: %s" % (type(e).__name__, e))
        # ⚠ 这里不做 v4l2-ctl: 设备被采集线程占着时 VIDIOC_S_FMT 会被 EBUSY 拒绝。
        #    采集线程重开前(设备空闲)会自己跑一遍, 见 _capture_loop。
        self.args.width = int(mode["w"])
        self.args.height = int(mode["h"])
        cap = Handler.capture
        reopened = False
        if cap is not None and hasattr(cap, "request_reopen"):
            cap.request_reopen()
            reopened = True
            log.append("已请求采集线程按 %dx%d 重开" % (mode["w"], mode["h"]))
        else:
            log.append("警告: 未找到采集对象, 可能要手动重启服务")
        return {"ok": reopened, "mode": mode, "log": log,
                "note": "画面会在 1~2 秒内按新模式重建"}

    # ---------- 具体响应 ----------
    def _serve_viewer(self):
        for p in (os.path.join(SCRIPT_DIR, "mipi_viewer.html"),
                  "/root/mipi_viewer.html",
                  "/home/rock/mipi_viewer.html"):
            if os.path.isfile(p):
                with open(p, "rb") as f:
                    body = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self._cors()
                self.end_headers()
                self.wfile.write(body)
                return
        body = FALLBACK_PAGE.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _serve_stream(self):
        self.send_response(200)
        self.send_header("Content-Type",
                         "multipart/x-mixed-replace; boundary=%s" % BOUNDARY)
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Connection", "close")
        self._cors()
        self.end_headers()

        self.hub._clients += 1
        last = -1
        try:
            while True:
                jpeg, last = self.hub.wait_next(last, timeout=10.0)
                if jpeg is None:
                    continue
                self.wfile.write(b"--" + BOUNDARY.encode() + b"\r\n")
                self.wfile.write(b"Content-Type: image/jpeg\r\n")
                self.wfile.write(b"Content-Length: %d\r\n\r\n" % len(jpeg))
                self.wfile.write(jpeg)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.hub._clients -= 1


FALLBACK_PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>MIPI Stream</title></head>
<body style="background:#111;color:#eee;font-family:sans-serif;text-align:center">
<h2>FPGA MIPI 画面</h2>
<img src="/stream" style="max-width:96vw;border:1px solid #333;border-radius:8px">
<p>完整控制台页面 mipi_viewer.html 未找到，请把它放到程序同目录。</p>
</body></html>"""


# ============================================================================
#  main
# ============================================================================
def main():
    ap = argparse.ArgumentParser(
        description="把 RK3576 MIPI 采集画面通过 HTTP MJPEG 推流并支持远程调参",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", default="/dev/video22",
                    help="V4L2 采集节点 (默认 /dev/video22)")
    ap.add_argument("--host", default="0.0.0.0", help="监听地址 (默认 0.0.0.0)")
    ap.add_argument("--port", type=int, default=9012, help="监听端口 (默认 9012)")
    ap.add_argument("--backend", default="auto",
                    choices=["auto", "opencv", "gst", "test"],
                    help="采集后端: auto/opencv/gst/test (默认 auto; "
                         "test=内置测试图案, 不接摄像头也能验证网页)")
    ap.add_argument("--width", type=int, default=1920, help="采集宽度")
    ap.add_argument("--height", type=int, default=1080, help="采集高度")
    ap.add_argument("--fourcc", default="NV16",
                    help="V4L2 像素格式 (默认 NV16=YUV422 全彩度; 也可试 NV12)")
    ap.add_argument("--yuv-matrix", default="709", choices=["601", "709"],
                    help="YUV->RGB 色彩矩阵 (默认 709, 与本工程 FPGA RTL 一致)")
    ap.add_argument("--yuv-range", default="limited",
                    choices=["limited", "full"],
                    help="YUV 量程 (默认 limited 16-235, 与本工程 FPGA RTL 一致)")
    ap.add_argument("--swap-uv", action="store_true",
                    help="交换 U/V (颜色明显不对时试一下)")
    ap.add_argument("--stream-width", type=int, default=1920,
                    help="推流基准宽度 (默认 1920 = 原生 1080p)")
    ap.add_argument("--conv-threads", type=int, default=4,
                    help="色彩转换并行度, 按行切分同时调用 C 库 (默认 4)")
    ap.add_argument("--enc-threads", type=int, default=3,
                    help="JPEG 编码线程数 (默认 3)")
    ap.add_argument("--cpu-affinity", default="auto",
                    help="绑定 CPU: auto(默认, 自动挑大核) / none / 形如 4-7")
    ap.add_argument("--v4l2ctl", default="v4l2-ctl", help="v4l2-ctl 可执行文件路径")
    ap.add_argument("--fpga-bus", type=int, default=9,
                    help="FPGA I2C 从机所在总线 (默认 9 = RK I2C9; 设 -1 关闭)")
    ap.add_argument("--fpga-addr", type=lambda s: int(s, 0), default=0x40,
                    help="FPGA I2C 从机地址 (默认 0x40)")
    ap.add_argument("--ai", action="store_true",
                    help="启用 AI 标注叠加(人体框/姿态骨架/危险动作); "
                         "模型在 <ai-dir>/models 下, 缺失则自动降级")
    ap.add_argument("--ai-dir", default=None,
                    help="AI 代码与模型目录 (默认自动找 /root/rk/ai)")
    ap.add_argument("--ai-fps", type=float, default=30.0,
                    help="AI 推理帧率上限 (默认 30; 与视频帧率无关)")
    ap.add_argument("--ai-det-model", default=None,
                    help="检测模型路径 (默认 <ai-dir>/models/yolov8n.rknn)")
    ap.add_argument("--ai-pose-model", default=None,
                    help="姿态模型路径 (默认 <ai-dir>/models/yolov8n-pose-hybrid.rknn)")
    ap.add_argument("--ai-source", default="raw", choices=["raw", "ai"],
                    help="开机默认画面源 raw=原图 / ai=AI 标注 (网页上可随时切)")
    ap.add_argument("--ai-kpt-margin", type=float, default=0.15,
                    help="一级框空间约束: 关节只保留在人体框 ± 该比例内(默认 0.15, <0=不限); "
                         "二级关键点与三级动作判定同时生效")
    ap.add_argument("--ai-kpt-max-dist", type=float, default=1.2,
                    help="距框中心门限(挡鬼点主力): 关节到框中心不得超过该值×(框对角/2), "
                         "默认 1.2, 0=关闭")
    ap.add_argument("--ai-det-interval", type=int, default=2,
                    help="一级检测跳帧(默认 2 = 每两帧检测一次); 1=每帧都检测(最准最慢), "
                         "调大可明显提高 AI 帧率")
    ap.add_argument("--ai-copy-frame", action="store_true",
                    help="推理前拷一份整帧(更干净但多 ~2.5ms/帧; 默认不拷)")
    ap.add_argument("--ai-zone", default="",
                    help="越界警戒区, 归一化坐标 例 '0.2,0.6;0.8,0.6;0.8,1;0.2,1'")
    ap.add_argument("--verbose", action="store_true", help="打印每条 HTTP 日志")
    ap.add_argument("--state-file", default=STATE_FILE_DEFAULT,
                    help="参数存档路径 (默认 同目录 state.json; 传空字符串=不保存)")
    args = ap.parse_args()

    hub = FrameHub()
    # 参数存档：页面重连 / 服务重启后自动恢复上次的取值
    state_file = (args.state_file or "").strip() or None
    if state_file and state_store is None:
        print("[state] 持久化不可用: %s" % _STATE_IMPORT_ERR, file=sys.stderr)
        state_file = None
    params = ParamStore(state_file)

    # 本板是 8 核异构: cpu0-3 = Cortex-A53@1.92G, cpu4-7 = Cortex-A72@2.11G。
    # 实测同一段 JPEG 编码在小核上 21.8fps、大核上 41.4fps, 差将近一倍,
    # 所以默认就把进程绑到最快的那批核上。
    aff = str(getattr(args, "cpu_affinity", "auto") or "").strip().lower()
    if aff and aff != "none":
        cpus = _pick_fast_cores() if aff == "auto" else _parse_cpu_list(aff)
        if cpus:
            try:
                os.sched_setaffinity(0, cpus)
                print("[cpu] 已绑定到大核 CPU %s" % sorted(cpus))
            except Exception as _e:
                print("[cpu] 绑定失败: %s" % _e, file=sys.stderr)

    backend = args.backend
    if backend == "auto":
        # 优先级: GStreamer 原生管线(gi) > OpenCV(cv2) > gst-launch 子进程
        if HAVE_GST_PY:
            backend = "gstlive"
        elif HAVE_CV2:
            backend = "opencv"
        else:
            backend = "gst"

    if backend == "gstlive":
        cap = GstLiveCapture(hub, params, args)
    elif backend == "opencv":
        cap = OpenCVCapture(hub, params, args)
    elif backend == "test":
        cap = TestCapture(hub, params, args)
    else:
        cap = GstCapture(hub, params, args)

    # ---- 可选: AI 叠加 (必须在 cap.start() 之前就位, 好让第一帧就能画) ----
    global AI_OVERLAY
    if args.ai:
        if AiOverlay is None:
            print("[ai] 无法启用: %s" % (_AI_IMPORT_ERR or "ai_overlay 不可用"),
                  file=sys.stderr)
        else:
            _zone = []
            if args.ai_zone:
                try:
                    for _pt in args.ai_zone.split(";"):
                        _x, _y = _pt.split(",")
                        _zone.append((float(_x), float(_y)))
                except Exception:
                    print("[ai] --ai-zone 解析失败, 已忽略", file=sys.stderr)
            AI_OVERLAY = AiOverlay(ai_dir=args.ai_dir,
                                   det_model=args.ai_det_model,
                                   pose_model=args.ai_pose_model,
                                   ai_fps=args.ai_fps,
                                   kpt_margin=args.ai_kpt_margin,
                                   kpt_scale_max=args.ai_kpt_max_dist,
                                   det_interval=args.ai_det_interval,
                                   copy_frame=args.ai_copy_frame,
                                   source=args.ai_source,
                                   zone=_zone,
                                   state_path=state_file,
                                   verbose=args.verbose)
            AI_OVERLAY.start()
            print("[ai] AI 叠加已启用: source=%s  %.1f fps  (网页上可切换画面源)"
                  % (AI_OVERLAY.source, AI_OVERLAY.ai_fps))
            # 存档里若上次就是「AI 标注」，启动时同样把 FPGA 预处理关掉
            if AI_OVERLAY.active and args.fpga_bus is not None and args.fpga_bus >= 0:
                print("[ai] 自动关闭 FPGA 预处理: %s"
                      % _fpga_pp_off(FpgaI2C(args.fpga_bus, args.fpga_addr)))

    cap.start()

    Handler.hub = hub
    Handler.params = params
    Handler.args = args
    Handler.capture = cap

    # FPGA 预处理参数走 I2C 从机 (RK I2C9 <-> FPGA L18/M18, 底板直连不用飞线)
    if args.fpga_bus is not None and args.fpga_bus >= 0:
        Handler.fpga = FpgaI2C(args.fpga_bus, args.fpga_addr)

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True

    ip = _guess_ip()
    print("=" * 66)
    print(" MIPI Web 推流服务已启动")
    print("   Python   : %s" % sys.executable)
    print("   采集设备 : %s" % args.device)
    print("   采集后端 : %s" % backend)
    print("   颜色解析 : YUV %s / %s%s"
          % (args.yuv_matrix.upper(), args.yuv_range,
             "  (U/V 已交换)" if args.swap_uv else ""))
    print("   可用后端 : gi/Gst=%s  cv2=%s  gst-launch=%s"
          % ("是" if HAVE_GST_PY else "否",
             "是" if HAVE_CV2 else "否",
             "是" if _have_cmd("gst-launch-1.0") else "否"))
    if not HAVE_CV2:
        print("              (cv2 不可用: %s)" % _CV2_ERR)
    if not HAVE_GST_PY:
        print("              (gi 不可用: %s)" % _GST_PY_ERR)
    print("   监听     : %s:%d" % (args.host, args.port))
    if Handler.fpga is not None:
        _fp_ok, _fp = Handler.fpga.snapshot()
        if _fp_ok:
            print("   FPGA I2C : %s @0x%02X 在线 | %s"
                  % (Handler.fpga.path, args.fpga_addr,
                     " ".join("%s=%d" % (k, v)
                              for k, v in _fp["regs"].items())))
            print("              状态: %s"
                  % " ".join("%s=%d" % (k, v)
                             for k, v in _fp["status"].items()))
        else:
            print("   FPGA I2C : %s @0x%02X 不可用 (%s)"
                  % (Handler.fpga.path, args.fpga_addr,
                     _fp.get("error", "?")))
    else:
        print("   FPGA I2C : 已关闭")
    print("   地址     :")
    print("       http://%s:%d/          浏览器直接看画面" % (ip, args.port))
    print("       http://%s:%d/stream    MJPEG 流" % (ip, args.port))
    print("   本地 HTML 请在 PC 上打开 mipi_viewer.html,")
    print("   把服务器地址填成  %s:%d" % (ip, args.port))
    print("=" * 66)

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n退出中 ...")
    finally:
        srv.server_close()
        if hasattr(cap, "stop"):
            cap.stop()
        cap.stop_flag.set()


def _guess_ip():
    """猜一下本机在局域网里的地址, 只是为了打印提示。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "192.168.137.100"
    finally:
        s.close()


if __name__ == "__main__":
    main()
