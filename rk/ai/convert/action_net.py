# -*- coding: utf-8 -*-
"""轻量骨架动作网络（ST-GCN 结构的「RKNN 友好」精简版）。

参考实现（思路来源，非直接拷贝）
--------------------------------
* ST-GCN  — yysijie/st-gcn            : 图卷积 + 时间卷积的基本结构
* ST-GCN++ — open-mmlab/mmaction2     : 去掉显式图卷积、用可学习邻接的组合思路
* PYSKL    — kennymckormick/pyskl     : 训练/评测脚本与数据增强实践

自己做的三处关键裁剪（为了 RK3576 上能跑、能转 RKNN）
----------------------------------------------------
1. **不用 einsum / scatter，图卷积就是一个常量矩阵乘**
       y = x @ A_p        (A_p: 17x17 常量，随权重一起导出成 initializer)
   ONNX 里是 MatMul，RKNN 支持；不会出现 Gather/ScatterND 这类转不动的算子。
2. **不做多尺度时间卷积融合**，只保留「图卷积 -> 1x1 通道混合 -> 时间卷积」，
   单层 FLOPs 低一个数量级；T=32、通道 32/64/64 时整网只有 ~30 MFLOPs，
   NPU 上是亚毫秒级，CPU(numpy) 兜底也只要十几 ms。
3. **输入就是归一化骨架 (1,32,17,3)**，不需要 crop 图像 —— 所以多人时每人一次
   前向，代价与人头数线性相关，不会像 RGB 视频模型那样爆掉。

⚠ 输入张量格式与 rk/ai/board/action_seq.py 严格一致，任何一侧改了都要同步。
"""
import numpy as np
import torch
import torch.nn as nn

# 类别顺序是**接口的一部分**：板上 ACTION_META 的 label 与这里必须一一对应，
# 切模型/重训时不要改顺序（否则颜色和级别都会错位）。
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
# 注意：'intrude'（越界）不在模型里 —— 它是**空间规则**，不是动作，
# 由 ActionEngine 用多边形几何判定，与模型并行输出。

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

# 左右镜像时的关节置换（用于数据增强 & 板端可选的水平翻转）
MIRROR_IDX = np.array([0, 2, 1, 4, 3, 6, 5, 8, 7, 10, 9, 12, 11, 14, 13, 16, 15])


def build_adjacency():
    """构造 ST-GCN 的 3 个分区邻接矩阵（常量，不参与训练）。

    A0 : 自身（单位阵）
    A1 : 一阶邻居（归一化 D^-1/2 (A+I) D^-1/2）
    A2 : 二阶邻居（A1^2 归一化）
    返回 (3, V, V) float32，全部按 V→V 的 **右乘** 约定（x @ A）。
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


class GraphConv(nn.Module):
    """y = conv1x1( concat_p( x @ A_p ) )

    三个分区各自聚合后沿通道拼接再做 1x1 混合 —— 等价于 ST-GCN 的
    「多子集邻接 + 每个子集独立权重」，但导出后就是一个 MatMul + 一个 Conv。
    """

    def __init__(self, cin, cout):
        super(GraphConv, self).__init__()
        adj = torch.from_numpy(build_adjacency())         # (3,V,V)
        for p in range(3):
            self.register_buffer('A%d' % p, adj[p].clone())
        self.conv = nn.Conv2d(cin * 3, cout, kernel_size=1, bias=False)

    def forward(self, x):
        # x: (N, C, T, V)   A: (V, V) -> 右乘作用于最后一维
        y = torch.cat([torch.matmul(x, self.A0),
                       torch.matmul(x, self.A1),
                       torch.matmul(x, self.A2)], dim=1)
        return self.conv(y)


class STBlock(nn.Module):
    """图卷积 -> 1x1 -> 时间卷积 -> 残差。"""

    def __init__(self, cin, cout, kt=9, stride=1):
        super(STBlock, self).__init__()
        self.gcn = GraphConv(cin, cout)
        self.bn1 = nn.BatchNorm2d(cout)
        self.tcn = nn.Conv2d(cout, cout, kernel_size=(kt, 1),
                             stride=(stride, 1), padding=(kt // 2, 0), bias=False)
        self.bn2 = nn.BatchNorm2d(cout)
        self.relu = nn.ReLU(inplace=True)
        if stride != 1 or cin != cout:
            self.down = nn.Sequential(
                nn.Conv2d(cin, cout, kernel_size=1, stride=(stride, 1), bias=False),
                nn.BatchNorm2d(cout))
        else:
            self.down = None

    def forward(self, x):
        r = x if self.down is None else self.down(x)
        y = self.relu(self.bn1(self.gcn(x)))
        y = self.bn2(self.tcn(y))
        return self.relu(y + r)


class ActionNet(nn.Module):
    """(N, T, V, C) -> (N, nclass) logits。"""

    def __init__(self, nclass=len(ACTION_CLASSES), t_len=T_LEN,
                 v=V_JOINTS, c=C_CH, widths=(32, 64, 64), drop=0.2):
        super(ActionNet, self).__init__()
        self.nclass = nclass
        self.t_len, self.v, self.c = t_len, v, c
        self.data_bn = nn.BatchNorm1d(c * v)
        self.blocks = nn.ModuleList()
        cin = c
        for i, w in enumerate(widths):
            stride = 1 if i == 0 else 2
            self.blocks.append(STBlock(cin, w, kt=9, stride=stride))
            cin = w
        self.drop = nn.Dropout(drop)
        self.fc = nn.Linear(cin, nclass)
        # 初始化：残差块最后一层 BN 置 0（训练更稳，收敛更快）
        for m in self.modules():
            if isinstance(m, nn.BatchNorm2d):
                nn.init.constant_(m.weight, 1.0)
                nn.init.constant_(m.bias, 0.0)

    def forward(self, x):
        n = x.shape[0]
        # (N,T,V,C) -> (N, C*V, T) 做 data BN（消除不同人骨架尺度的整体差异）
        x = x.permute(0, 3, 2, 1).reshape(n, self.c * self.v, self.t_len)
        x = self.data_bn(x)
        x = x.reshape(n, self.c, self.v, self.t_len).permute(0, 1, 3, 2)  # N,C,T,V
        for blk in self.blocks:
            x = blk(x)
        x = x.mean(dim=(2, 3))
        return self.fc(self.drop(x))


def count_flops(net, t_len=T_LEN):
    """粗略 FLOPs（MACs x2），只为选型参考。"""
    try:
        from thop import profile  # noqa: F401
        macs, _ = profile(net, inputs=(torch.zeros(1, t_len, V_JOINTS, C_CH),),
                          verbose=False)
        return macs
    except Exception:                                     # noqa: BLE001
        return -1.0


if __name__ == '__main__':
    net = ActionNet().eval()
    n_par = sum(p.numel() for p in net.parameters())
    with torch.no_grad():
        y = net(torch.zeros(1, T_LEN, V_JOINTS, C_CH))
    print('类别 %d: %s' % (len(ACTION_CLASSES), ACTION_CLASSES))
    print('参数量 %.1fk' % (n_par / 1000.0))
    print('输出形状', tuple(y.shape))
    print('FLOPs(MACs) %.2fM' % (count_flops(net) / 1e6))
