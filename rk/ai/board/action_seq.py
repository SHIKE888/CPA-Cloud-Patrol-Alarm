# -*- coding: utf-8 -*-
"""骨架序列缓冲 / 归一化 —— **训练(convert) 与部署(board) 共用同一份代码**。

⚠ 数值约定必须训练/部署完全一致，否则模型精度会莫名其妙掉。任何改动都要
   重新训练并同步板上/VM 两边的文件。

输入约定（与 rk/ai/convert/action_net.py 严格对应）
-----------------------------------------------------
T_LEN = 32 帧     按时间线性重采样到固定长度，15~60fps 都能用
V     = 17 关节   COCO 顺序（与 YOLOv8-pose 一致）
C     = 3 通道    x, y, valid
      x,y = (pixel - 髋中心) / 人体框高  → 大致 [-0.6, 0.6]
      valid = 1.0 该关节有效 / 0.0 无效（此时 x,y 记 0）

为什么按「髋中心 + 框高」归一化：
  这是唯一与**距离/画面位置/人体高矮**都无关的表示。原点画会捡到镜头畸变和
  人物在画面边角的位置偏差，按肩宽归一化会因为侧身而失真。髋中心 + 框高是
  姿态动作识别最稳的组合（ST-GCN / CTR-GCN 的标准做法）。
"""
import numpy as np

T_LEN = 32
V_JOINTS = 17
C_CH = 3

NOSE = 0
LS, RS = 5, 6
LW, RW = 9, 10
LH, RH = 11, 12
LK, RK = 13, 14
LA, RA = 15, 16
LE, RE = 7, 8

# ---------------------------------------------------------------- 人体比例常数
# 单位 = 身高。由 D:\datasets\action_data 的**直立 + 腿基本伸直**帧（15.3 万帧，
# 且 legY>0.38）取中位数标定。
#
# 为什么必须限制"腿伸直"：检测框高会**随姿势缩水** —— 下蹲时头变低，框跟着
# 变短（实测 squat 的髋→踝只有 0.350，站立是 0.416~0.429）。若标定时混进
# 蹲姿，比例会被拉偏，反过来又让"框高=身高"这个假设在下蹲时彻底失效。
#
# 为什么不用肩宽/髋宽做基准：随**视角**剧烈变化（侧身缩一半，相对 IQR 0.57）。
# 刚性量是**骨长**和躯干长度（IQR 0.09~0.12），与动作无关 —— 下蹲、挥砍、
# 抱臂都不会改变大腿有几根骨头长。
R_TORSO = 0.2895       # 肩中点 → 髋中点
R_THIGH = 0.2341       # 髋 → 膝
R_SHANK = 0.2294       # 膝 → 踝
R_NOSE_HIP = 0.3743    # 鼻 → 髋中点（锁头反推髋用）
R_UPARM = 0.1429       # 肩 → 肘
R_FOREARM = 0.1255     # 肘 → 腕
R_SHOULDER = 0.1413    # 肩宽（噪声大，只当兜底）
R_HIP = 0.0978         # 髋宽（同上）

# 关节估计的口径校验：用上面比例在 action_data 全量抽样上算
#   骨段估计 / 检测框高 = 1.00~1.03（idle/swing/throw/climb），
#   squat = 1.16（**框缩水的正确补偿**：蹲下时头变低把框拉矮了 14%），
#   fall = 1.06。所以骨段估计已经和"框高"同口径，不需额外系数。


def _seg(k, i, j):
    """两关节间距离（任一无效则 0）。"""
    if k[i, 2] <= 0 or k[j, 2] <= 0:
        return 0.0
    return float((((k[i, 0] - k[j, 0]) ** 2 + (k[i, 1] - k[j, 1]) ** 2) ** 0.5))


def _mid(k, i, j):
    """两关节中点（任一无效则 None）。"""
    if k[i, 2] <= 0 or k[j, 2] <= 0:
        return None
    return ((k[i, 0] + k[j, 0]) * 0.5, (k[i, 1] + k[j, 1]) * 0.5)


def _clipped(k, box, frame_size):
    """返回 (顶被切, 底被切)。frame_size 缺失时只看关键点。"""
    top = k[0, 2] <= 0 and k[1, 2] <= 0 and k[2, 2] <= 0
    feet = k[15, 2] <= 0 and k[16, 2] <= 0
    if box is not None and frame_size:
        W, H = float(frame_size[0]), float(frame_size[1])
        x1, y1, x2, y2 = [float(v) for v in box]
        top = top or y1 <= 2.0
        feet = feet or y2 >= H - 3.0
    return top, feet


def estimate_body(kps, box, frame_size=None, prefer=None):
    """估计（身高px, 原点(px), 是否完整可见, 依据）。

    这是**肢体不完整时不再误判**的关键：以前直接拿检测框高当身高，人只露出
    上半身时框高只有真实身高的一半 → 所有归一化位移翻倍 → 速度阈值全部失准，
    idle 被判成挥砍/奔跑。

    现在的做法：
      1. **尺度**：用可见的骨段长度 / 各自的人体比例，取中位数。骨长是刚性的，
         和动作无关；哪几段看得见就用哪几段，缺腿也能从躯干/上臂估出来。
         人完整可见时以**检测框高**为主（它最准），但会与关节估计交叉校验。
      2. **原点**：完整可见 → 髋中点（人体几何中心）；
         不能全包 → 优先**锁头**（鼻/眼反推髋位置），再退到肩中点、框中心。
    """
    k = np.asarray(kps, np.float32).reshape(-1, 3) if kps is not None else None
    if k is None:
        bh = max(1.0, float(box[3] - box[1])) if box is not None else 1.0
        cx = (float(box[0]) + float(box[2])) * 0.5
        cy = (float(box[1]) + float(box[3])) * 0.5
        return bh, (cx, cy), False, 'box'

    cut_top, cut_feet = _clipped(k, box, frame_size)
    head_ok = (k[0, 2] > 0) or (k[1, 2] > 0) or (k[2, 2] > 0)
    hip = _mid(k, LH, RH)
    sh = _mid(k, LS, RS)
    an = _mid(k, LA, RA)
    full = bool(head_ok and an is not None and not cut_top and not cut_feet)

    # ---- 1) 骨架尺寸估计：每段可见骨骼都是一个独立的身高估计
    ests = []                                     # (身高px, 权重, 名字)
    th = max(_seg(k, LH, LK), _seg(k, RH, RK))
    sh_leg = max(_seg(k, LK, LA), _seg(k, RK, RA))
    if hip is not None and sh is not None:
        d = float((((sh[0] - hip[0]) ** 2 + (sh[1] - hip[1]) ** 2) ** 0.5))
        if d > 1.0:
            ests.append((d / R_TORSO, 1.4, 'torso'))
    if th > 1.0:
        ests.append((th / R_THIGH, 1.2, 'thigh'))
    if sh_leg > 1.0:
        ests.append((sh_leg / R_SHANK, 1.0, 'shank'))
    if hip is not None and k[0, 2] > 0:
        d = float((((k[0, 0] - hip[0]) ** 2 + (k[0, 1] - hip[1]) ** 2) ** 0.5))
        if d > 1.0:
            ests.append((d / R_NOSE_HIP, 0.8, 'nose'))
    ua = max(_seg(k, LS, LE), _seg(k, RS, RE))
    fa = max(_seg(k, LE, LW), _seg(k, RE, RW))
    if ua > 1.0:
        ests.append((ua / R_UPARM, 0.6, 'uparm'))
    if fa > 1.0:
        ests.append((fa / R_FOREARM, 0.5, 'forearm'))
    sw = _seg(k, LS, RS)
    if sw > 1.0:
        ests.append((sw / R_SHOULDER, 0.3, 'shoulder'))
    hw = _seg(k, LH, RH)
    if hw > 1.0:
        ests.append((hw / R_HIP, 0.3, 'hipw'))

    if ests:
        vals = np.array([e[0] for e in ests], np.float64)
        wts = np.array([e[1] for e in ests], np.float64)
        order = np.argsort(vals)
        vals, wts = vals[order], wts[order]
        c = np.cumsum(wts)
        bh = float(vals[int(np.searchsorted(c, c[-1] * 0.5))])
        src = 'joints(%s)' % ','.join(str(ests[i][2]) for i in order[:3])
    else:
        bh, src = 0.0, 'none'

    # ---- 2) 尺度定案
    #   以**骨段估计**为主：它对"人只露出半个身子"和"下蹲时头变低把框拉矮"
    #   两种都稳。检测框高只在**一根骨头都看不见**时兜底。
    if bh <= 0:
        if box is not None:
            bh, src = max(1.0, float(box[3] - box[1])), 'box(no-bone)'
        else:
            bh, src = 1.0, 'none'

    # ---- 3) 原点：全包 → 髋中心；不能全包 → 锁头反推髋
    cand = []
    if hip is not None:
        cand.append(('hip', hip))
    if head_ok:
        if k[0, 2] > 0:
            cand.append(('head', (float(k[0, 0]), float(k[0, 1]) + R_NOSE_HIP * bh)))
        elif k[1, 2] > 0 and k[2, 2] > 0:
            ex = (float(k[1, 0]) + float(k[2, 0])) * 0.5
            ey = (float(k[1, 1]) + float(k[2, 1])) * 0.5
            cand.append(('head', (ex, ey + (R_NOSE_HIP - 0.017) * bh)))
    if sh is not None:
        cand.append(('shoulder', (sh[0], sh[1] + R_TORSO * bh)))

    # 完整可见 → 髋中心优先；否则按"锁头优先"的顺序
    order = ['hip', 'head', 'shoulder'] if full else ['head', 'hip', 'shoulder']
    if prefer in order:
        order = [prefer] + [o for o in order if o != prefer]
    anchor, anc_src = None, 'box'
    for name in order:
        for nm, pt in cand:
            if nm == name:
                anchor, anc_src = pt, name
                break
        if anchor is not None:
            break
    if anchor is None:
        if box is not None:
            anchor = ((float(box[0]) + float(box[2])) * 0.5,
                      (float(box[1]) + float(box[3])) * 0.5)
        else:
            anchor = (0.0, 0.0)
    return bh, anchor, full, '%s/%s' % (anc_src, src)


def _normalize(k, bh, anchor):
    out = np.zeros((V_JOINTS, C_CH), np.float32)
    cx, cy = anchor
    for i in range(V_JOINTS):
        if k[i, 2] > 0:
            out[i, 0] = (k[i, 0] - cx) / bh
            out[i, 1] = (k[i, 1] - cy) / bh
            out[i, 2] = 1.0
    return out


def normalize_frame(kps, box, frame_size=None):
    """单帧归一化（无状态版本，离线抽数据用）。

    kps : (17,3) float  ndarray，像素坐标 + 置信度（<=0 表示无效）
    box : (x1,y1,x2,y2) 人体框，像素；可以是**被画面切掉**的框
    -> (17,3) float32，x,y = (像素 - 原点) / 身高
    """
    if kps is None:
        return np.zeros((V_JOINTS, C_CH), np.float32)
    k = np.asarray(kps, np.float32).reshape(-1, 3)
    bh, anchor, _full, _src = estimate_body(k, box, frame_size)
    return _normalize(k, bh, anchor)


def resample(frames, t_len=T_LEN):
    """把 list[(t, (17,C))] 按时间线性重采样成 (t_len, 17, C) float32。

    帧间隔不均匀（AI 有丢帧）时也能得到等间隔序列 —— 这一点很关键：
    直接用最后 N 帧会让快慢动作被误判成不同类别。
    """
    n = len(frames)
    if n == 0:
        return np.zeros((t_len, V_JOINTS, C_CH), np.float32)
    if n == 1:
        return np.repeat(np.asarray(frames[0][1], np.float32)[None], t_len, 0)

    ts = np.asarray([f[0] for f in frames], np.float64)
    seq = np.stack([np.asarray(f[1], np.float32) for f in frames], 0)  # (N,17,C)
    order = np.argsort(ts)
    ts, seq = ts[order], seq[order]

    # 时间跨度太短（整段被压在 1 帧内）→ 直接按序列复制
    span = ts[-1] - ts[0]
    if span < 1e-3:
        idx = np.linspace(0, n - 1, t_len)
        return seq[np.round(idx).astype(np.int64)]

    grid = np.linspace(ts[0], ts[-1], t_len)
    out = np.empty((t_len, V_JOINTS, C_CH), np.float32)
    # 逐 (关节, 通道) 插值：np.interp 的 fp 只接受一维，不能直接整块传
    for v in range(seq.shape[1]):
        for c in range(C_CH):
            out[:, v, c] = np.interp(grid, ts, seq[:, v, c])
    # ❗ 第 3 通道是**有效标志**，绝不能线性插值：插出 0.097 这种值会被下游
    #   的 `>0` 当成"有效"，而那些采样点的 x,y 还是无效点的占位 0 ——
    #   相邻两点于是一个在原点、一个在真实位置，直接凭空造出 0.36 身高的
    #   位移（实测腕部速度 9.8 身高/秒，站着一动不动也会报挥砍）。
    #   按**时间上最近的原始样本**二值化。
    hi = np.clip(np.searchsorted(ts, grid), 1, len(ts) - 1)
    near = np.where((grid - ts[hi - 1]) <= (ts[hi] - grid), hi - 1, hi)
    out[:, :, 2] = (seq[near, :, 2] > 0).astype(np.float32)
    return out


class SeqBuffer(object):
    """单个 track 的滑窗缓冲。

    这里额外维护两件"跨帧状态"，都是为了让**肢体进出视野**时序列不抖：

    * `scale` —— 身高的 EMA。逐帧的骨架估计会有几 % 的跳动（被遮挡的骨段
      换了别的段来估），直接拿它归一化会造出假的"速度尖峰"。所以单帧最多
      改动 15%，再和上一帧做 EMA。
    * `mode`  —— 原点来源（hip/head/shoulder）。一旦锁上就尽量不变，
      避免在"髋中心"和"锁头"之间来回切换导致整个人体坐标整体平移一格。
    """

    def __init__(self, maxlen=120, scale_ema=0.25, max_step=0.15):
        self.frames = []          # [(t, (17,3))]
        self.maxlen = int(maxlen)
        self.scale_ema = float(scale_ema)
        self.max_step = float(max_step)
        self.scale = None         # 身高 EMA (px)
        self.mode = ''            # 原点来源，做粘滞
        self.full = False         # 上一帧是否完整可见
        self.info = ''            # 调试用："anchor/src"

    def push(self, t, kps, box, frame_size=None):
        bh, anchor, full, src = estimate_body(kps, box, frame_size,
                                              prefer=self.mode or None)
        if self.scale is None:
            self.scale = bh
        else:
            lo = self.scale * (1.0 - self.max_step)
            hi = self.scale * (1.0 + self.max_step)
            bh = lo if bh < lo else (hi if bh > hi else bh)
            self.scale = ((1.0 - self.scale_ema) * self.scale
                          + self.scale_ema * bh)
        self.mode = src.split('/')[0]
        self.full = full
        self.info = src

        if kps is None:
            norm = np.zeros((V_JOINTS, C_CH), np.float32)
        else:
            k = np.asarray(kps, np.float32).reshape(-1, 3)
            norm = _normalize(k, self.scale, anchor)
        self.frames.append((float(t), norm))
        if len(self.frames) > self.maxlen:
            del self.frames[:len(self.frames) - self.maxlen]

    def ready(self, need=T_LEN):
        return len(self.frames) >= need

    def build(self, t_len=T_LEN, seconds=None):
        """取最近 seconds 秒（默认全部）重采样成 (t_len,17,3)。"""
        if not self.frames:
            return np.zeros((t_len, V_JOINTS, C_CH), np.float32)
        fr = self.frames
        if seconds:
            t_end = fr[-1][0]
            fr = [f for f in fr if t_end - f[0] <= seconds]
        return resample(fr, t_len)
