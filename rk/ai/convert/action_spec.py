# -*- coding: utf-8 -*-
"""动作模型的**共享规格**（不依赖 torch / tf，谁都能 import）。

torch 版(action_net.py) 与 tf 版(action_net_tf.py) 必须使用同一份常量，
否则训出来的权重和板端推理对不上。
"""
import numpy as np

# 类别顺序是**接口的一部分**：板上 ACTION_META 的 label 与这里必须一一对应。
# 2026-10-24：'lying'（倒地不起）已合并进 'fall' —— 告警语义上
#   “正在倒”与“已经躺着”都是“有人倒下”，分开反而多一类、样本又少。
ACTION_CLASSES = [
    'idle',      # 0 无动作（必须有，否则模型会把静止判成某个动作）
    'fall',      # 1 跌倒 / 倒地不起（合并）
    'climb',     # 2 攀爬翻越
    'fight',     # 3 肢体冲突
    'run',       # 4 奔跑
    'handup',    # 5 举手求救
    'squat',     # 6 下蹲
    'swing',     # 7 挥砍
    'throw',     # 8 投掷
    'photo',     # 9 拍照
]
# 注意：'intrude'（越界）不在模型里 —— 它是**空间规则**，不是动作。

T_LEN = 32
V_JOINTS = 17
C_CH = 3

# COCO-17 骨架边（YOLOv8-pose 顺序）
COCO_EDGES = [
    (0, 1), (0, 2), (1, 3), (2, 4),          # 头
    (5, 6),                                   # 肩
    (5, 7), (7, 9), (6, 8), (8, 10),          # 手臂
    (5, 11), (6, 12), (11, 12),               # 躯干
    (11, 13), (13, 15), (12, 14), (14, 16),   # 腿
]

# 左右镜像时的关节置换（数据增强用）
MIRROR_IDX = np.array([0, 2, 1, 4, 3, 6, 5, 8, 7, 10, 9, 12, 11, 14, 13, 16, 15])

# 上臂 / 前臂长度（身高比例），演示与 IK 用
ARM_UPPER = 0.153
ARM_FORE = 0.122


def build_adjacency():
    """ST-GCN 的 3 个分区邻接矩阵（常量，不参与训练）。

    A0 : 自身（单位阵）
    A1 : 一阶邻居（归一化 D^-1/2 (A+I) D^-1/2）
    A2 : 二阶邻居（A1^2 归一化）
    返回 (3, V, V) float32，约定为 out[v] = sum_u A[v, u] * x[u]（右乘 / 左乘均可，
    因为这三个矩阵都是对称的）。
    """
    v = V_JOINTS
    a = np.eye(v, dtype=np.float64)
    for i, j in COCO_EDGES:
        a[i, j] = a[j, i] = 1.0

    def _norm(m):
        d = m.sum(1)
        d[d <= 1e-6] = 1.0
        dm = np.diag(1.0 / np.sqrt(d))
        return dm @ m @ dm

    a1 = _norm(a)
    a2 = _norm(a1 @ a1)
    return np.stack([np.eye(v, dtype=np.float32),
                     a1.astype(np.float32),
                     a2.astype(np.float32)], 0)
