# -*- coding: utf-8 -*-
"""轻量骨架动作网络 —— **TensorFlow / Keras 版**（本机 tf_gpu 环境即可训练）。

为什么有 TF 版
--------------
torch 版 (`action_net.py`) 结构与权重完全等价，但本机没有 torch、VM 也常离线；
`tf_gpu` 环境里就有 TF 2.10，所以训练/导出走 TF，torch 版留作对照实现。

两种布局的对应关系（很重要）
--------------------------
* torch 版内部用 (N, C, T, V)
* TF 版内部用 (N, T, V, C)  —— NHWC，TFLite / ONNX / RKNN 都原生友好
  两者算子一一对应：矩阵乘在 V 轴、Dense 在通道轴、Conv2D 只沿 T 方向卷积。
  导出的 `action_net.npz` **沿用 torch 版的 key 与排布**，所以板上
  `action_np.py` 的 numpy 前向不用改，还能直接做数值对照。

输入输出
--------
输入  kps   float32 (1, 32, 17, 3)   # x,y=(px-髋中心)/框高，第3通道=有效标志
输出  logits float32 (1, 11)
"""
import numpy as np
import tensorflow as tf
from tensorflow.keras import layers

from action_spec import (ACTION_CLASSES, T_LEN, V_JOINTS, C_CH,
                         build_adjacency)

BN_EPS = 1e-5          # 必须与 action_np.py 保持一致（torch 默认值）


class GraphAgg(layers.Layer):
    """分区邻接聚合：out[v] = sum_u A_p[v,u] * x[u]，p = 自身 / 一阶 / 二阶。"""

    def __init__(self, adj, **kw):
        super(GraphAgg, self).__init__(**kw)
        self.A = [tf.constant(adj[p], dtype=tf.float32) for p in range(3)]

    def call(self, x):                      # (N,T,V,C)
        xt = tf.transpose(x, [0, 1, 3, 2])  # (N,T,C,V)
        outs = []
        for p in range(3):
            y = tf.matmul(xt, tf.transpose(self.A[p]))     # (N,T,C,V)
            outs.append(tf.transpose(y, [0, 1, 3, 2]))     # (N,T,V,C)
        return tf.concat(outs, axis=-1)                    # (N,T,V,3C)

    def get_config(self):
        return super(GraphAgg, self).get_config()


class STBlock(layers.Layer):
    """图卷积 -> 1x1(Dense) -> 时间卷积 -> 残差。"""

    def __init__(self, cout, cin=0, kt=9, stride=1, idx=0, adj=None, **kw):
        super(STBlock, self).__init__(**kw)
        name = 'b%d' % idx
        self.agg = GraphAgg(adj, name=name + '_agg')
        self.dense = layers.Dense(cout, use_bias=False, name=name + '_gc')
        self.bn1 = layers.BatchNormalization(epsilon=BN_EPS, name=name + '_bn1')
        # ❗ padding 必须用**显式** ZeroPadding((kt//2, kt//2)) + 'valid'：
        #   Keras 的 padding='same' 在 stride=2 时是按 "前少后多" 补的
        #   （T=32,kt=9,s=2 → 前3后4），而 numpy/torch 侧是两边各 pad=kt//2，
        #   两者输出位置错开半帧，实测 logits 差 0.4。
        self.pad = layers.ZeroPadding2D(((kt // 2, kt // 2), (0, 0)))
        self.tcn = layers.Conv2D(cout, (kt, 1), strides=(stride, 1),
                                 padding='valid', use_bias=False,
                                 name=name + '_tcn')
        self.bn2 = layers.BatchNormalization(epsilon=BN_EPS, name=name + '_bn2')
        self.act = layers.ReLU()
        # 残差：stride!=1 **或通道数变化**都要加投影（block0 是 3->32）
        if stride != 1 or cin != cout:
            self.down = layers.Conv2D(cout, 1, strides=(stride, 1),
                                      padding='same', use_bias=False,
                                      name=name + '_down')
            self.bn_d = layers.BatchNormalization(epsilon=BN_EPS,
                                                  name=name + '_bn_d')
        else:
            self.down = None

    def call(self, x, training=False):
        r = x if self.down is None else self.bn_d(self.down(x), training=training)
        y = self.dense(self.agg(x))
        y = self.act(self.bn1(y, training=training))
        y = self.bn2(self.tcn(self.pad(y)), training=training)
        return self.act(y + r)


class ActionNetTF(tf.keras.Model):
    def __init__(self, nclass=len(ACTION_CLASSES), t_len=T_LEN, v=V_JOINTS,
                 c=C_CH, widths=(32, 64, 64), drop=0.2, **kw):
        super(ActionNetTF, self).__init__(**kw)
        self.t_len, self.v, self.c = t_len, v, c
        adj = build_adjacency()
        self.bn_data = layers.BatchNormalization(epsilon=BN_EPS, name='bn_data')
        self.blocks = []
        cin = c
        for i, w in enumerate(widths):
            blk = STBlock(w, cin=cin, kt=9, stride=(1 if i == 0 else 2),
                          idx=i, adj=adj, name='block%d' % i)
            self.blocks.append(blk)
            cin = w
        self.drop = layers.Dropout(drop)
        self.gap = layers.GlobalAveragePooling2D()
        self.fc = layers.Dense(nclass, name='fc')

    def call(self, x, training=False):
        # (N,T,V,C) -> (N,T,C,V) -> (N,T,C*V) 做 data BN（与 torch 的 C*V 排布一致）
        y = tf.transpose(x, [0, 1, 3, 2])
        y = tf.reshape(y, [-1, self.t_len, self.c * self.v])
        y = self.bn_data(y, training=training)
        y = tf.reshape(y, [-1, self.t_len, self.c, self.v])
        y = tf.transpose(y, [0, 1, 3, 2])            # (N,T,V,C)
        for blk in self.blocks:
            y = blk(y, training=training)
        y = self.gap(y)                              # (N,Cout)
        return self.fc(self.drop(y, training=training))


def build_model(**kw):
    return ActionNetTF(**kw)


# ---------------------------------------------------------------- 导出 numpy

def _bn_affine(layer):
    """BN 折成仿射：scale = gamma / sqrt(var + eps), bias = beta - mean*scale。"""
    g, b, m, v = layer.get_weights()
    scale = g / np.sqrt(v + BN_EPS)
    return scale.astype(np.float32), (b - m * scale).astype(np.float32)


def dump_npz(model, path, t_len=T_LEN):
    """导出成与 torch 版**完全同名同排布**的 npz，供 action_np.py 前向使用。"""
    out = {'t_len': np.int32(t_len)}
    s, b = _bn_affine(model.bn_data)
    out['data_bn_scale'], out['data_bn_bias'] = s, b

    out['nblocks'] = np.int32(len(model.blocks))
    strides = np.ones(len(model.blocks), np.int32)
    for i, blk in enumerate(model.blocks):
        p = 'b%d_' % i
        A = blk.agg.A
        out[p + 'A0'] = np.array(A[0], np.float32)
        out[p + 'A1'] = np.array(A[1], np.float32)
        out[p + 'A2'] = np.array(A[2], np.float32)
        # Dense kernel: (3C, Cout)  ->  (Cout, 3C)
        out[p + 'gcn_w'] = blk.dense.get_weights()[0].T.astype(np.float32)
        s1, b1 = _bn_affine(blk.bn1)
        out[p + 'bn1_scale'], out[p + 'bn1_bias'] = s1, b1
        # Conv2D kernel: (kt,1,Cin,Cout) -> (Cout,Cin,kt)
        k = blk.tcn.get_weights()[0]
        out[p + 'tcn_w'] = np.transpose(k[:, 0, :, :], (2, 1, 0)).astype(np.float32)
        out[p + 'kt'] = np.int32(k.shape[0])
        s2, b2 = _bn_affine(blk.bn2)
        out[p + 'bn2_scale'], out[p + 'bn2_bias'] = s2, b2
        if blk.down is not None:
            strides[i] = int(blk.down.strides[0])
            kd = blk.down.get_weights()[0]                     # (1,1,Cin,Cout)
            out[p + 'down_w'] = np.transpose(kd[0, 0]).astype(np.float32)
            sd, bd = _bn_affine(blk.bn_d)
            out[p + 'down_scale'], out[p + 'down_bias'] = sd, bd
    out['block_stride'] = strides
    out['fc_w'] = model.fc.get_weights()[0].T.astype(np.float32)
    out['fc_b'] = model.fc.get_weights()[1].astype(np.float32)
    np.savez(path, **out)
    return path


if __name__ == '__main__':
    m = build_model()
    y = m(tf.zeros((1, T_LEN, V_JOINTS, C_CH)), training=False)
    n_par = int(sum(np.prod(w.shape) for w in m.get_weights()))
    print('类别 %d: %s' % (len(ACTION_CLASSES), ACTION_CLASSES))
    print('参数量 %.1fk' % (n_par / 1000.0))
    print('输出', tuple(y.shape))
