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


def normalize_frame(kps, box):
    """单帧归一化。

    kps : (17,3) float  ndarray，像素坐标 + 置信度（<=0 表示无效）
    box : (x1,y1,x2,y2) 人体框，像素
    -> (17,3) float32
    """
    out = np.zeros((V_JOINTS, C_CH), np.float32)
    if kps is None:
        return out
    k = np.asarray(kps, np.float32).reshape(-1, 3)

    x1, y1, x2, y2 = [float(v) for v in box]
    bh = max(1.0, y2 - y1)

    # 髋中心：两个髋点都有效才用，否则退回框中心（下半身被遮挡时常见）
    if k[LH, 2] > 0 and k[RH, 2] > 0:
        cx = (k[LH, 0] + k[RH, 0]) * 0.5
        cy = (k[LH, 1] + k[RH, 1]) * 0.5
    else:
        cx, cy = (x1 + x2) * 0.5, (y1 + y2) * 0.5

    for i in range(V_JOINTS):
        if k[i, 2] > 0:
            out[i, 0] = (k[i, 0] - cx) / bh
            out[i, 1] = (k[i, 1] - cy) / bh
            out[i, 2] = 1.0
    return out


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
    return out


class SeqBuffer(object):
    """单个 track 的滑窗缓冲。"""

    def __init__(self, maxlen=120):
        self.frames = []          # [(t, (17,3))]
        self.maxlen = int(maxlen)

    def push(self, t, kps, box):
        self.frames.append((float(t), normalize_frame(kps, box)))
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
