# -*- coding: utf-8 -*-
"""numpy 版前向（无需 RKNN / onnxruntime / torch）。

用途
----
1. **一致性校验**：`export_action_onnx.py` 会拿它跟 PyTorch 对比，确保导出的
   权重摊平没摊错（这一步能提前抓出 90% 的"板上精度突然变差"问题）。
2. **CPU 兜底**：整网只有 ~30 MFLOPs，A72 单核十几 ms。rknn 模型缺失或
   rknnlite 初始化失败时，直接用这条路径，动作识别不会整体不可用。

实现注意：卷积/BN 的语义必须与 action_net.py 完全一致（含 padding、stride
和 BN 的 eps=1e-5），权重 key 由 export_action_onnx.dump_npz 固定。
"""
import numpy as np


def _bn(x, scale, bias, axis):
    """按 axis 广播的 BN（scale/bias 已是折好的仿射参数）。"""
    shape = [1] * x.ndim
    shape[axis] = -1
    return x * scale.reshape(shape) + bias.reshape(shape)


def _relu(x):
    return np.maximum(x, 0.0, out=x)


def _conv_t(x, w, kt, stride):
    """时间维卷积：x (N,Cin,T,V) @ w (Cout,Cin,kt) -> (N,Cout,Tout,V)。"""
    pad = kt // 2
    if pad:
        x = np.pad(x, ((0, 0), (0, 0), (pad, pad), (0, 0)))
    t_in = x.shape[2]
    t_out = (t_in - kt) // stride + 1
    out = None
    for k in range(kt):
        seg = x[:, :, k:k + stride * (t_out - 1) + 1:stride, :]     # (N,Cin,Tout,V)
        part = np.tensordot(seg, w[:, :, k], axes=([1], [1]))       # (N,Tout,V,Cout)
        part = np.transpose(part, (0, 3, 1, 2))
        out = part if out is None else out + part
    return out.astype(np.float32)


class NumpyActionNet(object):
    """从 action_net.npz 载入并做前向。线程不安全（共享临时缓冲），单线程使用。"""

    def __init__(self, npz_path):
        z = np.load(npz_path)
        self.z = {k: z[k] for k in z.files}
        self.nblocks = int(self.z['nblocks'])
        self.t_len = int(self.z['t_len']) if 't_len' in self.z else 32

    # ---------------------------------------------------------------- 前向
    def predict_batch(self, x):
        """x: (N,T,17,3) float32 -> (logits (N,K), probs (N,K))"""
        x = np.asarray(x, np.float32)
        if x.ndim == 3:
            x = x[None]
        n, t, v, c = x.shape
        z = self.z

        # (N,T,V,C) -> (N, C*V, T) -> BN -> (N,C,T,V)
        y = np.transpose(x, (0, 3, 2, 1)).reshape(n, c * v, t)
        y = _bn(y, z['data_bn_scale'], z['data_bn_bias'], axis=1)
        y = y.reshape(n, c, v, t).transpose(0, 1, 3, 2).astype(np.float32)

        for i in range(self.nblocks):
            p = 'b%d_' % i
            stride = int(z['block_stride'][i])

            # ---- 图卷积分区聚合 + 1x1 通道混合
            g = np.concatenate([np.matmul(y, z[p + 'A0']),
                                np.matmul(y, z[p + 'A1']),
                                np.matmul(y, z[p + 'A2'])], axis=1)
            g = np.tensordot(g, z[p + 'gcn_w'], axes=([1], [1]))     # (N,T,V,Cout)
            g = np.transpose(g, (0, 3, 1, 2))
            g = _relu(_bn(g, z[p + 'bn1_scale'], z[p + 'bn1_bias'], axis=1))

            # ---- 时间卷积
            g = _conv_t(g, z[p + 'tcn_w'], int(z[p + 'kt']), stride)
            g = _bn(g, z[p + 'bn2_scale'], z[p + 'bn2_bias'], axis=1)

            # ---- 残差
            if (p + 'down_w') in z:
                r = np.tensordot(y, z[p + 'down_w'], axes=([1], [1]))  # (N,T,V,Cout)
                r = np.transpose(r, (0, 3, 1, 2))
                if stride > 1:
                    r = r[:, :, ::stride, :]
                r = _bn(r, z[p + 'down_scale'], z[p + 'down_bias'], axis=1)
            else:
                r = y
            y = _relu(g + r)

        feat = y.mean(axis=(2, 3))
        logits = feat @ z['fc_w'].T + z['fc_b']
        logits = logits.astype(np.float32)

        e = np.exp(logits - logits.max(axis=1, keepdims=True))
        probs = (e / e.sum(axis=1, keepdims=True)).astype(np.float32)
        return logits, probs

    def predict_one(self, seq):
        _, p = self.predict_batch(seq[None])
        return p[0]
