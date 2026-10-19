#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""det_core.py —— RK3576 两级人体检测 / 姿态关键点推理核心。

两级流水线
    Stage-1  yolov8n       (COCO 80 类，仅取 person=0)      -> 人体框
    Stage-2  yolov8n-pose  (单类 person + 17 关键点)        -> 每个人体框内的肢体关节

模型来自 airockchip/rknn_model_zoo 预导出 ONNX，经 ../convert/convert_rknn.py
转成 rk3576 / INT8 的 .rknn。后处理与官方 C 实现（postprocess.cc）保持一致：

  * 检测头输出 (1, 64+ncls, H, W)：前 64 = 4×16 的 DFL 分布，后 ncls = 类别 logits（未过 sigmoid）
  * pose 模型额外输出 (1, 51, 8400)：17 个关键点的 (x, y, conf)，坐标已是 letterbox(640) 像素
    anchor 索引 = 分支累加偏移 + y*W + x，分片顺序 = 模型输出顺序（stride 8 → 16 → 32）

依赖：numpy、cv2；（板上）rknnlite。无 NPU 时可把 RKNN 后端关掉做纯后处理单测。
"""
from __future__ import annotations

import math
import os
import re
import time

import cv2
import numpy as np

# ---------------------------------------------------------------- 常量

COCO17_NAMES = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
]

# rknn_model_zoo 的骨架定义（1-based → 这里转成 0-based）
SKELETON = [
    (15, 13), (13, 11), (16, 14), (14, 12), (11, 12), (5, 11), (6, 12),
    (5, 6), (5, 7), (6, 8), (7, 9), (8, 10), (1, 2), (0, 1), (0, 2),
    (1, 3), (2, 4), (3, 5), (4, 6),
]

# 与 rknn_model_zoo python demo 一致的调色板
_PALETTE = np.array([
    [255, 128, 0], [255, 153, 51], [255, 178, 102], [230, 230, 0], [255, 153, 255],
    [153, 204, 255], [255, 102, 255], [255, 51, 255], [102, 178, 255], [51, 153, 255],
    [255, 153, 153], [255, 102, 102], [255, 51, 51], [153, 255, 153], [102, 255, 102],
    [51, 255, 51], [0, 255, 0], [0, 0, 255], [255, 0, 0], [255, 255, 255],
], dtype=np.uint8)
KPT_COLOR = _PALETTE[[16, 16, 16, 16, 16, 0, 0, 0, 0, 0, 0, 9, 9, 9, 9, 9, 9]]
LIMB_COLOR = _PALETTE[[9, 9, 9, 9, 7, 7, 7, 0, 0, 0, 0, 0, 16, 16, 16, 16, 16, 16, 16]]

_BINS = np.arange(16, dtype=np.float32).reshape(1, 16, 1, 1)


# ---------------------------------------------------------------- 基础工具

def letterbox(img, size=(640, 640), color=114, interp=None):
    """等比缩放 + 居中填充。返回 (canvas, scale, pad_x, pad_y)。

    interp: None = 自动(放大 LINEAR / 缩小 AREA)；可显式指定。
            1080p→640 用 INTER_LINEAR 比 INTER_AREA 快一倍多，检测精度差别很小。
    """
    h, w = img.shape[:2]
    tw, th = size
    r = min(tw / float(w), th / float(h))
    nw, nh = int(round(w * r)), int(round(h * r))
    if interp is None:
        interp = cv2.INTER_LINEAR if r > 1 else cv2.INTER_AREA
    resized = cv2.resize(img, (nw, nh), interpolation=interp)
    canvas = np.full((th, tw, 3), color, dtype=img.dtype)
    px, py = (tw - nw) // 2, (th - nh) // 2
    canvas[py:py + nh, px:px + nw] = resized
    return canvas, r, px, py


# letterbox 画布缓存: key=(th, tw, dtype) -> {'buf', 'shape', 'pos'}
#
# 为什么要缓存：`np.full((640,640,3), 114)` 每次都要分配 + memset 1.2MB，
# 实测 letterbox_rgb 总耗时 3.09ms，而裸 resize+cvtColor 只要 0.80ms ——
# 差的 2.2ms 几乎全是分配画布和 memset（GPU/UMat 那条路更慢：上传+下载 7.7ms）。
# 1080p 输入的 nw/nh/px/py 每帧都一样，画布只需把中间区域覆盖掉即可。
#
# ⚠ 返回的 canvas 是**复用缓冲**：下次调用会被覆盖，只能同步用完即弃
#   （persons() / pose_in() 都是先喂给 infer 再丢弃，安全）。
# ⚠ 单个进程内共用；det 与 pose 交替使用同一块 640 画布是安全的，
#   因为两者都是同步串行使用，且每次都会把中间区域整块重写。
_LB_CACHE = {}


def letterbox_rgb(img, size=(640, 640), color=114, interp=None, slot=''):
    """letterbox 并直接给出 RGB。

    缩放与转色的先后顺序按“哪边像素少先做哪边”来选：
      * 大图缩小（1080p→640）：**先缩再转色** —— 转色只处理 640×360，
        而不是整块 640×640 画布（原来多转 44% 的像素，~0.35ms/帧）；
      * 小图放大（人体 ROI→640）：先在原尺寸转色再放大，
        免得把 1.2MB 的画布做一次无谓的 cvtColor。

    slot: 缓存槽名。**一级检测与二级姿态必须用不同的 slot** ——
    两者的贴图区域尺寸差异很大，共用一个缓冲会每帧都触发整块重填，
    等于把复用的收益全部吃掉。
    返回的 canvas 是复用缓冲，下次同 slot 调用即失效。
    """
    h, w = img.shape[:2]
    tw, th = size
    r = min(tw / float(w), th / float(h))
    if interp is None:
        interp = cv2.INTER_LINEAR if r > 1 else cv2.INTER_AREA
    nw, nh = int(round(w * r)), int(round(h * r))
    px, py = (tw - nw) // 2, (th - nh) // 2

    key = (slot, th, tw, img.dtype.str)
    ent = _LB_CACHE.get(key)
    if ent is None:
        ent = {'buf': np.empty((th, tw, 3), dtype=img.dtype),
               'shape': None, 'pos': None}
        _LB_CACHE[key] = ent
    canvas = ent['buf']
    if ent['shape'] != (nh, nw) or ent['pos'] != (px, py):
        # 贴图区域变了（典型：二级姿态的 ROI 每人每帧都不一样）：
        # 整块重填一次底色，比重新 malloc 一块还快。
        canvas[:] = color
        ent['shape'], ent['pos'] = (nh, nw), (px, py)

    if r <= 1.0:
        resized = cv2.resize(img, (nw, nh), interpolation=interp)
        canvas[py:py + nh, px:px + nw] = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
        return canvas, r, px, py
    rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    canvas[py:py + nh, px:px + nw] = cv2.resize(rgb, (nw, nh), interpolation=interp)
    return canvas, r, px, py


def _sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def _body_scale(kps):
    """用躯干长度估一个象素级体型基准（不够可靠时返回 0）。"""
    def mid(i, j):
        a, b = kps[i], kps[j]
        if a[2] <= 0 or b[2] <= 0:
            return None
        return ((float(a[0]) + float(b[0])) * 0.5,
                (float(a[1]) + float(b[1])) * 0.5)

    sh = mid(5, 6)          # 两肩中点
    hp = mid(11, 12)        # 两髀中点
    if sh and hp:
        d = math.hypot(sh[0] - hp[0], sh[1] - hp[1])
        if d > 4:
            return d, sh, hp
    if sh is None:
        return 0.0, None, None
    a, b = kps[5], kps[6]
    if a[2] > 0 and b[2] > 0:
        w = math.hypot(float(a[0]) - float(b[0]), float(a[1]) - float(b[1]))
        if w > 4:
            return w * 1.6, sh, None
    return 0.0, None, None


def nms_numpy(boxes, scores, classes, thres):
    """按类别做 NMS。boxes: (N,4) xyxy。返回保留索引（已按分数降序）。"""
    if boxes.shape[0] == 0:
        return np.zeros((0,), dtype=np.int64)
    keep = []
    order = np.argsort(-scores)
    cls = classes[order]
    bx = boxes[order]
    area = np.maximum(0.0, bx[:, 2] - bx[:, 0]) * np.maximum(0.0, bx[:, 3] - bx[:, 1])
    suppressed = np.zeros(order.size, dtype=bool)
    for i in range(order.size):
        if suppressed[i]:
            continue
        keep.append(i)
        j = np.nonzero((~suppressed) & (cls == cls[i]))[0]
        j = j[j > i]
        if j.size == 0:
            continue
        xx1 = np.maximum(bx[i, 0], bx[j, 0])
        yy1 = np.maximum(bx[i, 1], bx[j, 1])
        xx2 = np.minimum(bx[i, 2], bx[j, 2])
        yy2 = np.minimum(bx[i, 3], bx[j, 3])
        inter = np.maximum(0.0, xx2 - xx1) * np.maximum(0.0, yy2 - yy1)
        iou = inter / np.maximum(1e-9, area[i] + area[j] - inter)
        suppressed[j[iou > thres]] = True
    return order[np.array(keep, dtype=np.int64)]


# ---------------------------------------------------------------- RKNN 封装

class RKNNModel(object):
    """rknnlite 的极简封装：一次 load、复用 runtime。"""

    def __init__(self, path, name='model', core_mask=None):
        self.path = path
        self.name = name
        self.ok = False
        self.err = ''
        self.rknn = None
        self.out_shapes = []
        self.infer_ms = 0.0

        if not path or not os.path.isfile(path):
            self.err = '模型文件不存在: %s' % path
            return
        try:
            from rknnlite.api import RKNNLite  # noqa: WPS433
        except Exception as e:  # noqa: BLE001
            self.err = 'rknnlite 不可用: %s' % e
            return

        try:
            self.rknn = RKNNLite(verbose=False)
            if self.rknn.load_rknn(path) != 0:
                raise RuntimeError('load_rknn 失败')
            # ★ 默认用 **双核** (NPU_CORE_0_1)。RK3576 的 NPU 是双核，而
            #   NPU_CORE_AUTO 只会挑一个核跑，另一个核全程 0% —— 外部看到的现象
            #   就是“NPU 占用才 20~40%，却怎么也快不起来”。
            #   板上实测 (probe_npu_core.py，640 输入单次推理墙钟):
            #     det  yolov8n-slim    : AUTO 25.2ms -> 双核 17.3ms  (-31%)
            #     pose yolov8n-pose-hyb: AUTO 29.9ms -> 双核 25.8ms  (-14%)
            if core_mask is None:
                core_mask = getattr(RKNNLite, 'NPU_CORE_0_1', None)
            cm = RKNNLite.NPU_CORE_AUTO if core_mask is None else core_mask
            if self.rknn.init_runtime(core_mask=cm) != 0:
                # 双核初始化失败(老 runtime / 模型不支持) -> 退回单核自动，不阻断
                if cm != RKNNLite.NPU_CORE_AUTO:
                    if self.rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_AUTO) != 0:
                        raise RuntimeError('init_runtime 失败')
                else:
                    raise RuntimeError('init_runtime 失败')
            self.ok = True
        except Exception as e:  # noqa: BLE001
            self.err = str(e)
            self.rknn = None

    def infer(self, img_rgb):
        """img_rgb: HWC uint8 RGB（尺寸需与模型输入一致）。返回输出数组列表。"""
        if not self.ok:
            raise RuntimeError('[%s] 未就绪: %s' % (self.name, self.err))
        x = img_rgb
        if x.ndim == 3:
            x = x[None]                      # rknnlite 要求 4 维（含 batch）
        t0 = time.time()
        outs = self.rknn.inference(inputs=[x], data_format='nhwc')
        self.infer_ms = (time.time() - t0) * 1000.0
        if not self.out_shapes and outs:
            for o in outs:
                self.out_shapes.append(tuple(o.shape))
        return outs

    def release(self):
        if self.rknn is not None:
            try:
                self.rknn.release()
            except Exception:  # noqa: BLE001
                pass
            self.rknn = None


# ---------------------------------------------------------------- 检测后处理

class Obj(object):
    __slots__ = ('box', 'score', 'cls', 'kps')

    def __init__(self, box, score, cls, kps=None):
        self.box = box            # (4,) x1y1x2y2，letterbox(640) 像素
        self.score = float(score)
        self.cls = int(cls)
        self.kps = kps            # (17,3) 或 None，letterbox(640) 像素


def _as_chw(o):
    """把 4D 输出统一成 (C,H,W)，兼容 NCHW 与 NHWC 两种排布。"""
    if getattr(o, 'ndim', 0) != 4:
        return None
    _, a, b, c = o.shape
    if a == b and c <= 256 and a > 16:          # 形如 (1,H,W,C)
        return np.ascontiguousarray(o[0].transpose(2, 0, 1))
    return o[0]


def _pick_kps_out(outputs):
    """找出关键点输出并 reshape 成 (51, N)，行序 = 17 点 × (x,y,conf)。"""
    for o in outputs:
        if getattr(o, 'ndim', 0) == 4 and o.shape[1] == 17 and o.shape[2] == 3:
            return o.reshape(51, -1)
        if getattr(o, 'ndim', 0) == 3 and o.shape[1] in (17, 51) and o.shape[-1] >= 100:
            return o.reshape(51, -1)
    return None


def _decode_heads(outputs, conf_thres, keep_cls=None, want_kps=False,
                  input_size=640):
    """解析 yolov8 检测头（坐标在 input_size 的 letterbox 空间）。

    兼容两种导出布局（实测 airockchip 官方 onnx 就是这两种）：
      A) 分离式  yolov8n.onnx      : 每个 stride 输出 DFL(64ch) + 类别(80ch，已 sigmoid) + aux(1ch)
      B) 合并式  yolov8n-pose.onnx : 每个 stride 输出 (64+ncls)ch，cls 为 logits（未 sigmoid）
    规则：同一 H 下若存在 64ch 张量 → 分离式；否则把 >64ch 的张量拆成 DFL + cls。
    """
    groups = {}
    kps_out = None
    if want_kps:
        kps_out = _pick_kps_out(outputs)

    # 布局 D: (1, C, N) 扁平输出（ultralytics 原生导出，C = box4 + cls[+kpt51]）
    for o in outputs:
        if getattr(o, 'ndim', 0) == 3 and o.shape[0] == 1 and o.shape[1] >= 5 \
                and o.shape[-1] >= 100 and o.shape[1] != 51 and o.shape[1] != 17:
            return _decode_flat(o[0], conf_thres, keep_cls, kps_out, input_size,
                                want_kps=want_kps)

    for o in outputs:
        if getattr(o, 'ndim', 0) == 4 and o.shape[1] == 17 and o.shape[2] == 3:
            continue                                  # 关键点分支，已单独取出
        chw = _as_chw(o)
        if chw is not None:
            groups.setdefault(chw.shape[1], []).append(chw)

    objs = []
    offset = 0
    # 关键点分片顺序与模型输出顺序一致（airockchip 官方实现假定 stride 8→16→32）
    for H in sorted(groups.keys(), reverse=True):
        stride = float(input_size) / H
        arrs = groups[H]
        dfl = cls = xywh = None
        for a in arrs:
            if a.shape[0] == 64:
                dfl = a
        if dfl is not None:
            # 分离式布局: DFL 单独一个张量, 剩下的就是类别头。
            # 注意类别头可能是 1 通道（精简成 person-only 的模型就是这种），
            # 也可能附带一个 1 通道的 aux —— aux 在输出顺序上排在类别头之后。
            for a in arrs:
                if a.shape[0] != 64:
                    cls = a
                    break
        else:
            for a in arrs:
                if a.shape[0] > 64:
                    dfl, cls = a[:64], a[64:]
                    break
            if dfl is None:
                # 第三种布局: ultralytics 原生导出 (1, 4+ncls, N) ——
                # 它的 box 已经过 DFL 积分成了 xywh（letterbox 像素，无需 stride）
                for a in arrs:
                    if 4 < a.shape[0] < 64:
                        xywh, cls = a[:4], a[4:]
                        break
        if xywh is not None:
            ncls = cls.shape[0]
            idxs = (list(range(ncls)) if keep_cls is None
                    else [c for c in keep_cls if c < ncls])
            if not idxs:
                offset += H * H
                continue
            use = cls[idxs]
            lo, hi = float(use.min()), float(use.max())
            conf = use if (0.0 <= lo and hi <= 1.0) else _sigmoid(use)
            if conf.ndim == 2:
                conf = conf[None, :, :]
            hits = np.argwhere(conf > conf_thres)          # (N,3) -> c,y,x
            if hits.size:
                c, y, x = hits[:, 0], hits[:, 1], hits[:, 2]
                sc = conf[c, y, x]
                b4 = xywh.reshape(4, H, -1)                # (4,H,W)
                cx, cy = b4[0, y, x], b4[1, y, x]
                bw, bh = b4[2, y, x], b4[3, y, x]
                boxes = np.stack([cx - bw * 0.5, cy - bh * 0.5,
                                  cx + bw * 0.5, cy + bh * 0.5], axis=1)
                for i in range(boxes.shape[0]):
                    objs.append(Obj(boxes[i], sc[i], idxs[int(c[i])], None))
            offset += H * H
            continue
        if dfl is None or cls is None:
            offset += H * H
            continue

        ncls = cls.shape[0]
        idxs = list(range(ncls)) if keep_cls is None else [c for c in keep_cls if c < ncls]
        if not idxs:
            offset += H * H
            continue
        use = cls[idxs]
        lo, hi = float(use.min()), float(use.max())
        conf = use if (0.0 <= lo and hi <= 1.0) else _sigmoid(use)
        if conf.ndim == 2:
            conf = conf[None, :, :]

        hits = np.argwhere(conf > conf_thres)          # (N,3) -> c,y,x
        if hits.size:
            c, y, x = hits[:, 0], hits[:, 1], hits[:, 2]
            sc = conf[c, y, x]

            dist = dfl.reshape(4, 16, H, dfl.shape[2])[:, :, y, x]     # (4,16,N)
            d = dist - dist.max(axis=1, keepdims=True)
            np.exp(d, out=d)
            d /= d.sum(axis=1, keepdims=True)
            ltrb = (d * np.arange(16, dtype=np.float32).reshape(1, 16, 1)).sum(axis=1)

            cx = (x + 0.5) * stride
            cy = (y + 0.5) * stride
            boxes = np.stack([
                cx - ltrb[0] * stride,
                cy - ltrb[1] * stride,
                cx + ltrb[2] * stride,
                cy + ltrb[3] * stride,
            ], axis=1)

            kps_all = None
            if kps_out is not None:
                anchor = offset + y * H + x
                kps_all = kps_out[:, anchor].reshape(17, 3, -1)

            for i in range(boxes.shape[0]):
                kp = kps_all[:, :, i].copy() if kps_all is not None else None
                objs.append(Obj(boxes[i], sc[i], idxs[int(c[i])], kp))
        offset += H * H
    return objs


def _guess_input_size(path, default=640):
    """从模型文件名里猜输入边长：`yolov8n-pose-384-hybrid.rknn` → 384。

    横竖都支持的模型没有（都是正方形输入）；猜不出来就用 default。
    """
    m = re.search(r'-(\d{3,4})(?:[-.]|$)', os.path.basename(str(path or '')))
    if m:
        v = int(m.group(1))
        if 128 <= v <= 1280 and v % 32 == 0:
            return v
    return default


def _decode_flat(a, conf_thres, keep_cls, kps_out, input_size, want_kps=False):
    """解析 (C, N) 扁平输出：C = box4 + cls(n) [+ kpt51]。

    这是 ultralytics 原生导出的姿态/检测模型：每个 anchor 一列，box 已是 xywh 像素坐标。

    ★ 关键点有两种摆法，**必须都支持**：
      A) 独立张量：另有一个 (1,17,3,N) 或 (1,51,N)（→ kps_out 非空，640 官方导出就是这种）
      B) **内联在尾部**：C = 4 + ncls + 51，52 行里后 51 行就是 17 点 ×(x,y,conf)
         （→ ultralytics 原生导出的小尺寸 pose，(1,56,3024) 这种）
      以前只认 A：B 的 51 行 kpt 会被当成 52 个类别，导致 kps=None、
      “cls 被量化抹平”的兜底也一起失效 → 表现为**有框无骨架 / 直接没框**。

    实测坑：类别分支会被 INT8 量化抹平成全 0（画面里明明有人但 cls=0），
    所以 cls 没命中时改用“关键点置信度”兜底判定有人（一人一个 pose，足够用）。
    """
    n = a.shape[1]
    segs = [max(1, int(input_size // s)) ** 2 for s in (8, 16, 32)]
    if sum(segs) != n:
        segs = [n // 3] * 3

    kps_all = kps_out
    if kps_all is None and want_kps and a.shape[0] - 4 - 51 >= 1:
        ncls = a.shape[0] - 4 - 51
        kps_all = a[4 + ncls:]                          # (51, N)，视图，不拷贝
    else:
        ncls = a.shape[0] - 4 - (51 if kps_all is not None else 0)
    if ncls <= 0:
        return []
    has_kpt = kps_all is not None
    if has_kpt:
        # 扁平导出的关键点 conf **不是概率而是 logits**（实测 max 1.8 这种），
        # 官方 rknn_model_zoo 的分离式输出才已经 sigmoid 过。
        _c = kps_all[2::3]
        if _c.size and (float(_c.max()) > 1.0 or float(_c.min()) < 0.0):
            kps_all = kps_all.copy()
            kps_all[2::3] = _sigmoid(kps_all[2::3])
    objs = []
    pos = 0
    for m in segs:
        seg = a[:, pos:pos + m]
        if seg.size == 0:
            break
        pos0 = pos
        pos += m
        idxs = (list(range(ncls)) if keep_cls is None
                else [c for c in keep_cls if c < ncls])
        if not idxs:
            continue
        u = seg[4:4 + ncls][idxs]
        lo, hi = float(u.min()), float(u.max())
        conf = u if (0.0 <= lo and hi <= 1.0) else _sigmoid(u)
        if conf.ndim == 1:
            conf = conf[None, :]
        if has_kpt and float(conf.max()) <= conf_thres:
            kc = kps_all[2::3, pos0:pos0 + m].max(axis=0)
            # ⚠ 必须要求 kc 真有区分度：量化把 kpt conf 压成 0 时 sigmoid(0) 恒为 0.5，
            #   直接用会让 3024 个 anchor **全部**通过（实测过一次，框糊满整屏）。
            if kc.size == m and float(kc.max()) >= 0.55:
                conf = np.maximum(conf, kc[None, :])
        hits = np.argwhere(conf > conf_thres)
        if not hits.size:
            continue
        c, y = hits[:, 0], hits[:, 1]
        sc = conf[c, y]
        cx, cy, bw, bh = seg[0, y], seg[1, y], seg[2, y], seg[3, y]
        boxes = np.stack([cx - bw * 0.5, cy - bh * 0.5,
                          cx + bw * 0.5, cy + bh * 0.5], axis=1)
        for i in range(boxes.shape[0]):
            kp = None
            if has_kpt:
                kp = kps_all[:, pos0 + int(y[i])].reshape(17, 3).copy()
            objs.append(Obj(boxes[i], sc[i], idxs[int(c[i])], kp))
    return objs


def _post(objs, nms_thres, max_det):
    if not objs:
        return []
    boxes = np.array([o.box for o in objs], dtype=np.float32)
    scores = np.array([o.score for o in objs], dtype=np.float32)
    classes = np.array([o.cls for o in objs], dtype=np.int32)
    keep = nms_numpy(boxes, scores, classes, nms_thres)
    keep = keep[:max_det]
    return [objs[int(i)] for i in keep]


# ---------------------------------------------------------------- 两级检测器

class TwoStageDetector(object):
    """Stage-1 人体检测 + Stage-2 ROI 姿态估计。

    两级的输入尺寸可以不同（例：det 640 + pose 384），因为二级只在一个小 ROI 上跑，
    输入小一圈就能省一大截 NPU 时间（耗时≈面积比）。
    尺寸默认从模型文件名里猜（`yolov8n-pose-384-hybrid.rknn` → 384），
    也可以用 `det_input` / `pose_input` 显式指定。
    """

    INPUT = (640, 640)          # 兼容旧代码（等于 det 的输入尺寸）

    def __init__(self, det_model, pose_model,
                 det_conf=0.35, nms_thres=0.45, kpt_conf=0.30,
                 max_persons=4, roi_expand=1.15,
                 kpt_margin=0.15, kpt_scale_max=1.2, person_cls=0,
                 det_interval=1, det_interp=None,
                 det_input=None, pose_input=None, spread_pose=True,
                 pose_budget=2):
        self.det = RKNNModel(det_model, 'det') if det_model else None
        self.pose = RKNNModel(pose_model, 'pose') if pose_model else None
        self.det_size = int(det_input or _guess_input_size(det_model))
        self.pose_size = int(pose_input or _guess_input_size(pose_model))
        self.INPUT = (self.det_size, self.det_size)
        self.det_conf = det_conf
        self.nms_thres = nms_thres
        self.kpt_conf = kpt_conf
        self.max_persons = max_persons
        self.roi_expand = roi_expand
        # 检测跳帧：每 N 次 run() 才跑一次一级检测（中间帧用缓存框 + 姿态框回写跟随）
        self.det_interval = max(1, int(det_interval))
        # 检测帧是否跳过姿态（把两级长尾摊平，帧率能明显上去；关节滞后一帧）
        self.spread_pose = bool(spread_pose)
        self._last_kps = []
        self.interp = det_interp if det_interp is not None else cv2.INTER_LINEAR
        # 一级框对二级的空间约束: 允许关节超出人体框的宽/高的多少倍
        #   >=0 : 超出即判为不可见(推荐 0.1~0.3)
        #   < 0 : 不限制(旧行为)
        self.kpt_margin = float(kpt_margin)
        # 距框中心门限: 关节到框中心的距离不得超过 kpt_scale_max ×(框对角/2)。
        #   1.2 ≈ “框内 + 手脚稍微伸出框”都放行；穿屏鬼点(≥2)一律剔除。
        #   0 = 关闭。这个参数是“挡鬼点”的主力，误剔太多就调大。
        self.kpt_scale_max = float(kpt_scale_max)
        self.person_cls = person_cls
        # det_ran / stage2_n 是“本次调用”的标志位；frames / det_n / pose_n 是
        # 累计计数，上层(ai_overlay)靠它们的增量算出“一级检测帧率 / 姿态帧率”。
        self.stat = {'det_ms': 0.0, 'pose_ms': 0.0, 'stage2_n': 0,
                     'kpt_dropped': 0, 'kpt_far': 0, 'det_ran': 0,
                     'frames': 0, 'det_n': 0, 'pose_n': 0, 'pose_skip': 0}
        self._tick = 0
        self._cached = []          # 跳帧期间复用的检测框 [(box, score), ...]
        # 多人时的**姿态预算**: 每帧最多跑几个人的姿态（<=0 = 不限制）。
        # 二级姿态是逐人串行的（N 人 = N × ~23ms），4 个人就会把帧率拖到 10fps。
        # 设成 2 后每帧只更新 2 个人，其余人沿用上一帧关节（按框中心位移补偿），
        # 帧率不再随人数线性下降；代价是被跳过的人骨架更新得慢一点。
        # 人数 <= 预算时行为与不限制完全一致。
        self.pose_budget = int(pose_budget or 0)
        self._pose_rr = 0           # 轮转起点，保证每个人都轮得到
        self._prev_pose = []        # 上一轮 [(box, kps), ...] 供跳过的那些复用

    # -------------------------------------------------- 工具
    @staticmethod
    def _map_back(box, scale, px, py, W, H):
        x1 = (box[0] - px) / scale
        y1 = (box[1] - py) / scale
        x2 = (box[2] - px) / scale
        y2 = (box[3] - py) / scale
        return np.array([max(0.0, min(W - 1.0, x1)), max(0.0, min(H - 1.0, y1)),
                         max(0.0, min(W - 1.0, x2)), max(0.0, min(H - 1.0, y2))],
                        dtype=np.float32)

    def prepare(self, img_bgr, slot='det'):
        """只做一级 letterbox，供 AI 流水的前处理线程单独调用。

        ⚠ **不要在这里拿 `_det_lock`**：它必须和主推理线程真正并行，
          而主线程跑一轮 run() 要 18~20ms，抢锁会把流水收益全部抵消。
          本函数只读 `self.INPUT` / `self.interp`（构造后不变），无需保护。
        ⚠ 返回的是复用画布：调用方必须保证 slot 不冲突
          （流水双缓冲用 `pipe0` / `pipe1` 轮流，避免盖掉推理正在用的那块）。
        """
        return letterbox_rgb(img_bgr, self.INPUT, interp=self.interp, slot=slot)

    def persons(self, img_bgr, pack=None):
        """Stage-1：返回原图坐标下的人体框列表 [(box, score), ...]。

        pack 可由 prepare() 预先算好（流水前处理），省掉这一次 letterbox。
        """
        H, W = img_bgr.shape[:2]
        rgb, scale, px, py = pack if pack is not None else self.prepare(img_bgr)
        outs = self.det.infer(rgb)
        self.stat['det_ms'] = self.det.infer_ms
        self.stat['det_ran'] = 1
        objs = _decode_heads(outs, self.det_conf, keep_cls=[self.person_cls],
                             input_size=self.det_size)
        objs = _post(objs, self.nms_thres, max_det=64)
        res = []
        for o in objs:
            res.append((self._map_back(o.box, scale, px, py, W, H), o.score))
        res.sort(key=lambda t: -(t[0][2] - t[0][0]) * (t[0][3] - t[0][1]))
        return res

    @staticmethod
    def _kps_to_box(kps, box, margin=0.12):
        """用关节外接矩形估一个更新后的框（跳帧时靠它跟随人体）。

        只采信“距框中心不超过 0.6 倍框对角”的点，避免个别鬼点把框拉大拉偏
        （框一旦被拉偏，下一帧 ROI 也跟着偏，形成正反馈）。
        """
        x1, y1, x2, y2 = [float(v) for v in box]
        xc, yc = (x1 + x2) * 0.5, (y1 + y2) * 0.5
        lim = math.hypot(x2 - x1, y2 - y1) * 0.6
        m = kps[:, 2] > 0
        if int(m.sum()) < 6:
            return None
        dx = kps[:, 0] - xc
        dy = kps[:, 1] - yc
        m &= (np.hypot(dx, dy) <= lim)
        if int(m.sum()) < 6:
            return None
        xs, ys = kps[m, 0], kps[m, 1]
        bx1, by1, bx2, by2 = float(xs.min()), float(ys.min()), float(xs.max()), float(ys.max())
        w, h = bx2 - bx1, by2 - by1
        if w < 8 or h < 8:
            return None
        return np.array([bx1 - w * margin, by1 - h * margin,
                         bx2 + w * margin, by2 + h * margin], dtype=np.float32)

    def pose_in(self, img_bgr, box):
        """Stage-2：对单个原图 ROI 跑姿态，返回原图坐标的 (17,3) 关键点。"""
        H, W = img_bgr.shape[:2]
        x1, y1, x2, y2 = box
        bw, bh = x2 - x1, y2 - y1
        if bw < 8 or bh < 8:
            return None
        ex = self.roi_expand
        cx, cy = (x1 + x2) * 0.5, (y1 + y2) * 0.5
        rw, rh = bw * ex, bh * ex
        rx1 = int(max(0, cx - rw * 0.5))
        ry1 = int(max(0, cy - rh * 0.5))
        rx2 = int(min(W, cx + rw * 0.5))
        ry2 = int(min(H, cy + rh * 0.5))
        roi = img_bgr[ry1:ry2, rx1:rx2]
        if roi.size == 0:
            return None

        rgb, scale, px, py = letterbox_rgb(roi, (self.pose_size, self.pose_size),
                                           slot='pose')
        outs = self.pose.infer(rgb)
        self.stat['pose_ms'] = self.pose.infer_ms

        objs = _decode_heads(outs, self.det_conf, keep_cls=[0], want_kps=True,
                             input_size=self.pose_size)
        objs = _post(objs, self.nms_thres, max_det=1)
        if not objs or objs[0].kps is None:
            return None

        k = objs[0].kps.astype(np.float32)          # (17,3) in 640-space
        k[:, 0] = (k[:, 0] - px) / scale + rx1
        k[:, 1] = (k[:, 1] - py) / scale + ry1

        # ---- 级联空间约束: 三道门限, 目标都是“只相信人身上的关节” -----------
        # 姿态模型在遮挡/背景相似时会把关节输出到很远的地方(常见是贴着 ROI
        # 左上角), 这些点会拉出穿屏的骨架线、也会把动作判定带偏。
        xc, yc = (x1 + x2) * 0.5, (y1 + y2) * 0.5
        diag = math.hypot(bw, bh)

        # (1) 框 ± margin
        #     ⚠ 注意: ROI 本身是框外扩 roi_expand 的, 所以 ROI 内的点最多只在
        #     框外 (roi_expand-1)/2 = 7.5%, 永远小于默认的 15% ——
        #     也就是说这一道单靠自己拦不住 ROI 内的鬼点, 主力是下面的 (2).
        if self.kpt_margin is not None and self.kpt_margin >= 0:
            mx, my = bw * self.kpt_margin, bh * self.kpt_margin
            bad = ((k[:, 0] < x1 - mx) | (k[:, 0] > x2 + mx) |
                   (k[:, 1] < y1 - my) | (k[:, 1] > y2 + my))
            if bad.any():
                k[bad, 2] = 0.0
                self.stat['kpt_dropped'] = int(bad.sum())

        # (2) 距框中心门限（主力）
        #     只相信“以框中心为圆心、半径 kpt_scale_max×(框对角/2)”内的关节。
        #     ⚙ 为什么不用“肩/髀估体型”那一套？因为那是自举失败的：一旦某个肩点
        #     自己飘出去，用它算出来的“躯干长”会被撞大 → 门限跟着变松 →
        #     其它鬼点全部放行，而且髀干本身会拉出一条穿屏的长线。
        #     一级检测框是完全独立于姿态的，用它定尺最稳。
        if self.kpt_scale_max and self.kpt_scale_max > 0:
            lim = self.kpt_scale_max * (diag * 0.5)
            d = np.hypot(k[:, 0] - xc, k[:, 1] - yc)
            far = (k[:, 2] > 0) & (d > lim)
            if far.any():
                k[far, 2] = 0.0
                self.stat['kpt_far'] = int(far.sum())

        k[k[:, 2] < self.kpt_conf] = 0.0            # 低置信点清零
        self.stat['stage2_n'] = 1
        self.stat['pose_n'] += 1
        return k

    def run(self, img_bgr, prepared=None):
        """完整两级：返回 [ {box, score, kps}, ... ] （原图坐标）。

        prepared: 由 prepare() 预先算好的一级输入包 (rgb, scale, px, py)。
          流水模式下前处理线程已经做过了，传进来就省掉一次 letterbox；
          不传则在本函数内现算（单线程模式，行为与以前完全一致）。
        det_interval > 1 时会跳帧：只在第 1、1+N、1+2N… 次调用里跑一级检测，
        中间帧直接复用缓存框；每帧的姿态结果会用"关节外接框"回写缓存，
        所以人走动时框依然能跟得上（只是不会发现新出现的人）。

        spread_pose=True 时，跑一级检测的那一帧**不再跑姿态**（关节沿用上一帧）：
        两级串在一个帧里会出现一个“长尾帧”（det 30ms + pose 15ms = 45ms），
        帧率就被它拖住；拆开以后每帧都是短帧，实测帧率能明显上去。
        代价是这一帧的骨架位置略滞后（一帧，约 35ms）。
        """
        self._tick += 1
        self.stat['frames'] += 1
        need_det = (self.det_interval <= 1 or not self._cached
                    or (self._tick - 1) % self.det_interval == 0)
        if need_det and self.det is not None and self.det.ok:
            self._cached = self.persons(img_bgr, prepared)[:self.max_persons]
            self.stat['det_n'] += 1
            if self.spread_pose and self.det_interval > 1 and self._last_kps:
                # 这一帧只做检测：直接返回新框 + 上一帧的关节
                self.stat['stage2_n'] = 0
                return self._spread_out()
        elif not self._cached and self.det is not None and self.det.ok:
            self._cached = self.persons(img_bgr, prepared)[:self.max_persons]

        out = []
        new_cache = []
        # 这一帧轮到谁跑姿态：人数超过预算时按轮转取预算个，其余复用上一轮关节
        n = len(self._cached)
        budget = self.pose_budget
        if budget > 0 and n > budget:
            rot = self._pose_rr % n
            run_idx = set((rot + i) % n for i in range(budget))
            self._pose_rr = (rot + budget) % n
        else:
            run_idx = None
        for idx, (box, score) in enumerate(self._cached):
            if run_idx is None or idx in run_idx:
                kps = self.pose_in(img_bgr, box) if self.pose is not None else None
            else:
                kps = self._reuse_kps(box)
                self.stat['pose_skip'] += 1
            use_box = np.asarray(box, dtype=np.float32)
            if kps is not None and self.det_interval > 1:
                nb = self._kps_to_box(kps, box)
                if nb is not None:
                    # 只接受"不会缩太多"的更新（避免遮挡时越长越小）
                    ow = max(1.0, box[2] - box[0]) * max(1.0, box[3] - box[1])
                    nw = max(1.0, nb[2] - nb[0]) * max(1.0, nb[3] - nb[1])
                    if 0.55 * ow <= nw <= 2.5 * ow:
                        use_box = (0.45 * use_box + 0.55 * nb).astype(np.float32)
            new_cache.append((use_box, score))
            out.append({'box': use_box, 'score': float(score), 'kps': kps})
        if self.det_interval > 1 and new_cache:
            self._cached = new_cache
        self._last_kps = [o['kps'] for o in out]
        self._prev_pose = [(np.asarray(o['box'], dtype=np.float32), o['kps'])
                           for o in out]
        return out

    def _reuse_kps(self, box):
        """未轮到跑姿态的人：捡上一轮最近的那份关节，并按框中心位移平移。

        限距是为了防止“上一个人的关节”被错配到另一个人身上
        （人数变化时 _cached 的下标会错位，所以不能按下标取）。
        """
        if not self._prev_pose:
            return None
        x1, y1, x2, y2 = [float(v) for v in box]
        cx, cy = (x1 + x2) * 0.5, (y1 + y2) * 0.5
        lim = max(8.0, 0.6 * max(1.0, x2 - x1, y2 - y1))
        best, bestd = None, lim
        for pb, pk in self._prev_pose:
            if pk is None:
                continue
            pcx = (float(pb[0]) + float(pb[2])) * 0.5
            pcy = (float(pb[1]) + float(pb[3])) * 0.5
            d = math.hypot(pcx - cx, pcy - cy)
            if d < bestd:
                bestd, best = d, (pb, pk)
        if best is None:
            return None
        dx = cx - (float(best[0][0]) + float(best[0][2])) * 0.5
        dy = cy - (float(best[0][1]) + float(best[0][3])) * 0.5
        if abs(dx) < 0.5 and abs(dy) < 0.5:
            return best[1]
        k = best[1].copy()
        k[:, 0] += dx
        k[:, 1] += dy
        return k

    def _spread_out(self):
        """spread 模式：用新检测框 + 上一帧的关节拼一个返回。"""
        out = []
        for idx, (box, score) in enumerate(self._cached):
            kps = self._last_kps[idx] if idx < len(self._last_kps) else None
            use_box = np.asarray(box, dtype=np.float32)
            if kps is not None:
                nb = self._kps_to_box(kps, box)
                if nb is not None:
                    ow = max(1.0, box[2] - box[0]) * max(1.0, box[3] - box[1])
                    nw = max(1.0, nb[2] - nb[0]) * max(1.0, nb[3] - nb[1])
                    if 0.55 * ow <= nw <= 2.5 * ow:
                        use_box = (0.45 * use_box + 0.55 * nb).astype(np.float32)
            out.append({'box': use_box, 'score': float(score), 'kps': kps})
        if out:
            self._cached = [(np.asarray(o['box'], dtype=np.float32), o['score'])
                            for o in out]
            self._prev_pose = [(np.asarray(o['box'], dtype=np.float32), o['kps'])
                               for o in out]
        return out


# ---------------------------------------------------------------- 绘制

def draw_pose(img, kps, color=(0, 255, 0), thickness=2, radius=3):
    """在 img 上画 17 点骨架（kps 为原图像素坐标，低置信点为 0）。"""
    if kps is None:
        return
    for a, b in SKELETON:
        pa, pb = kps[a], kps[b]
        if pa[2] <= 0 or pb[2] <= 0:
            continue
        if pa[0] <= 0 and pa[1] <= 0:
            continue
        if pb[0] <= 0 and pb[1] <= 0:
            continue
        cv2.line(img, (int(pa[0]), int(pa[1])), (int(pb[0]), int(pb[1])),
                 color, thickness, lineType=cv2.LINE_AA)
    for i in range(kps.shape[0]):
        x, y, c = kps[i]
        if c <= 0 or (x <= 0 and y <= 0):
            continue
        cv2.circle(img, (int(x), int(y)), radius,
                   [int(v) for v in KPT_COLOR[i]], -1, lineType=cv2.LINE_AA)


def draw_person(img, box, score, label=None, color=(0, 255, 0), thick=2,
                kps=None, show_score=True):
    x1, y1, x2, y2 = [int(v) for v in box]
    cv2.rectangle(img, (x1, y1), (x2, y2), color, thick, lineType=cv2.LINE_AA)
    txt = ''
    if label:
        txt = label
    if show_score:
        txt = ('%s %.2f' % (txt, score)).strip()
    if txt:
        (tw, th), base = cv2.getTextSize(txt, cv2.FONT_HERSHEY_SIMPLEX, 0.55, 1)
        ty = max(th + 4, y1 - 4)
        cv2.rectangle(img, (x1, ty - th - 4), (x1 + tw + 6, ty + base - 4),
                      color, -1, lineType=cv2.LINE_AA)
        cv2.putText(img, txt, (x1 + 3, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                    (0, 0, 0), 1, cv2.LINE_AA)
    if kps is not None:
        draw_pose(img, kps, color=color, thickness=thick, radius=max(2, thick + 1))


# ---------------------------------------------------------------- 跟踪 + 平滑

class SimpleTracker(object):
    """IoU 贪心匹配 + 关键点 EMA 平滑（只为显示稳定与动作时序需要）。

    两个入口共用：`ai_webstream.py`（独立 9013 服务）与 `web/ai_overlay.py`（挂在 9012 里）。
    """

    def __init__(self, iou_thres=0.3, alpha=0.55, max_age=1.2):
        self.tracks = {}          # tid -> {'box':..,'kps':..,'t':..}
        self.next_id = 1
        self.iou = iou_thres
        self.alpha = alpha
        self.max_age = max_age

    @staticmethod
    def _iou(a, b):
        x1, y1 = max(a[0], b[0]), max(a[1], b[1])
        x2, y2 = min(a[2], b[2]), min(a[3], b[3])
        iw, ih = max(0.0, x2 - x1), max(0.0, y2 - y1)
        inter = iw * ih
        ua = ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)
        return inter / max(1e-9, ua)

    def update(self, t, dets):
        for tid in [k for k, v in self.tracks.items() if t - v['t'] > self.max_age]:
            self.tracks.pop(tid, None)

        pairs = []
        for di, d in enumerate(dets):
            for tid, tr in self.tracks.items():
                pairs.append((self._iou(d['box'], tr['box']), di, tid))
        pairs.sort(reverse=True)

        used_d, used_t = set(), set()
        for iou, di, tid in pairs:
            if iou < self.iou or di in used_d or tid in used_t:
                continue
            used_d.add(di)
            used_t.add(tid)
            dets[di]['tid'] = tid
            self._smooth(tid, dets[di], t)

        for di, d in enumerate(dets):
            if di in used_d:
                continue
            tid = self.next_id
            self.next_id += 1
            d['tid'] = tid
            self.tracks[tid] = {'box': d['box'].copy(), 'kps': None, 't': t}
            if d.get('kps') is not None:
                self.tracks[tid]['kps'] = d['kps'].copy()

        return dets

    def _smooth(self, tid, det, t):
        tr = self.tracks[tid]
        a = self.alpha
        box = tr['box'] * (1 - a) + det['box'] * a
        tr['box'] = box
        tr['t'] = t
        det['box'] = box
        kps = det.get('kps')
        if kps is not None:
            old = tr.get('kps')
            if old is not None and old.shape == kps.shape:
                sm = old * (1 - a) + kps * a
                # 只在“两帧都有效”的点上做平滑；当前帧无效的点保留旧坐标，
                # 否则模型对不可见关节的鬼坐标（比如贴着 ROI 左上角）会被混进
                # 历史里，下一帧又拿被污染的值继续平滑 —— 表现就是“点自己游走”。
                both = (old[:, 2] > 0) & (kps[:, 2] > 0)
                sm[~both] = old[~both]
                sm[:, 2] = kps[:, 2]
                det['kps'] = sm
                tr['kps'] = sm.copy()
            else:
                tr['kps'] = kps.copy()
