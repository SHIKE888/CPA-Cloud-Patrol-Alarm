# -*- coding: utf-8 -*-
"""把 action_net.pt 导出成 ONNX（给 RKNN 转换）和 action_net.npz（numpy 兜底）。

为什么同时导 npz
----------------
RKNN 转换只在 VM 上有环境，板子上没有。而 **numpy 版前向**可以让我们
* 在 PC/VM 上就验证「导出后数值是否和 PyTorch 一致」；
* 在板子没转 RKNN、或者 rknnlite 初始化失败时，用 CPU 兜底跑（这个网只有
  ~30 MFLOPs，A72 单核十几 ms，比规则还便宜）。
权重 NPZ 的 key 命名由本脚本固定，`rk/ai/board/action_np.py` 按同一套 key 读取。

用法
----
    python export_action_onnx.py --ckpt action_net.pt --out action_net
    # 产出 action_net.onnx + action_net.npz
"""
import argparse
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

import torch                                              # noqa: E402

from action_net import ActionNet, T_LEN, V_JOINTS, C_CH  # noqa: E402


def dump_npz(net, path, t_len):
    """把 eval 模式下的权重摊平成 numpy，供 action_np.py 前向使用。

    BN 直接折进 scale/bias（推理期 BN 是仿射，折了更快也更省事）。
    """
    sd = {k: v.detach().cpu().numpy().astype(np.float32)
          for k, v in net.state_dict().items()}
    out = {'t_len': np.int32(t_len)}

    def _bn(prefix):
        g = sd[prefix + '.weight']
        b = sd[prefix + '.bias']
        m = sd[prefix + '.running_mean']
        v = sd[prefix + '.running_var']
        eps = 1e-5
        scale = g / np.sqrt(v + eps)
        return scale.astype(np.float32), (b - m * scale).astype(np.float32)

    s, b = _bn('data_bn')
    out['data_bn_scale'] = s
    out['data_bn_bias'] = b

    nblk = len([k for k in sd if k.endswith('gcn.conv.weight')])
    out['nblocks'] = np.int32(nblk)
    for i in range(nblk):
        p = 'blocks.%d.' % i
        out['b%d_A0' % i] = sd[p + 'gcn.A0']
        out['b%d_A1' % i] = sd[p + 'gcn.A1']
        out['b%d_A2' % i] = sd[p + 'gcn.A2']
        out['b%d_gcn_w' % i] = sd[p + 'gcn.conv.weight'][:, :, 0, 0]
        s1, b1 = _bn(p + 'bn1')
        out['b%d_bn1_scale' % i] = s1
        out['b%d_bn1_bias' % i] = b1
        out['b%d_tcn_w' % i] = sd[p + 'tcn.weight'][:, :, :, 0]     # (Co,Ci,kt)
        out['b%d_kt' % i] = np.int32(sd[p + 'tcn.weight'].shape[2])
        s2, b2 = _bn(p + 'bn2')
        out['b%d_bn2_scale' % i] = s2
        out['b%d_bn2_bias' % i] = b2
        if (p + 'down.0.weight') in sd:
            out['b%d_down_w' % i] = sd[p + 'down.0.weight'][:, :, 0, 0]
            ds, db = _bn(p + 'down.1')
            out['b%d_down_scale' % i] = ds
            out['b%d_down_bias' % i] = db
            m = sd[p + 'down.0.stride'] if False else None   # 占位，无实际作用
            del m
    out['fc_w'] = sd['fc.weight']
    out['fc_b'] = sd['fc.bias']
    # down 的 stride：由结构决定（block0 stride1, 其余 stride2），写在 meta 里
    strides = np.ones(nblk, np.int32)
    for i in range(1, nblk):
        strides[i] = 2
    out['block_stride'] = strides
    np.savez(path, **out)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ckpt', default='action_net.pt')
    ap.add_argument('--out', default='action_net')
    ap.add_argument('--opset', type=int, default=12)
    args = ap.parse_args()

    ck = torch.load(args.ckpt, map_location='cpu')
    net = ActionNet()
    net.load_state_dict(ck['state_dict'])
    net.eval()
    t_len = int(ck.get('t_len', T_LEN))
    print('载入 %s  classes=%s val_acc=%s' %
          (args.ckpt, ck.get('classes'), ck.get('val_acc')))

    onnx_path = args.out + '.onnx'
    npz_path = args.out + '.npz'
    dummy = torch.zeros(1, t_len, V_JOINTS, C_CH)
    torch.onnx.export(net, dummy, onnx_path, opset_version=args.opset,
                      input_names=['kps'], output_names=['logits'],
                      do_constant_folding=True, dynamic_axes=None)
    print('ONNX  ->', onnx_path, '(%.1f KB)' % (os.path.getsize(onnx_path) / 1024.0))

    dump_npz(net, npz_path, t_len)
    print('NPZ   ->', npz_path, '(%.1f KB)' % (os.path.getsize(npz_path) / 1024.0))

    # 一致性检查：ONNX Runtime (@VM) 与 numpy 版都跟 PyTorch 比一遍
    x = np.random.RandomState(0).randn(4, t_len, V_JOINTS, C_CH).astype(np.float32)
    x[:, :, :, 2] = 1.0
    with torch.no_grad():
        ref = net(torch.from_numpy(x)).numpy()

    try:
        import onnxruntime as ort
        sess = ort.InferenceSession(onnx_path, providers=['CPUExecutionProvider'])
        got = sess.run(['logits'], {'kps': x})[0]
        print('ONNX   vs torch  max|diff| = %.3e' % np.abs(got - ref).max())
    except ImportError:
        print('（未装 onnxruntime，跳过 ONNX 一致性检查）')

    sys.path.insert(0, os.path.join(_HERE, '..', 'board'))
    try:
        from action_np import NumpyActionNet
        nn_ = NumpyActionNet(npz_path)
        got2, _ = nn_.predict_batch(x)
        print('numpy  vs torch  max|diff| = %.3e' % np.abs(got2 - ref).max())
        pred = got2.argmax(1)
        print('numpy 预测', pred.tolist(), ' torch 预测', ref.argmax(1).tolist())
    except Exception as e:                                # noqa: BLE001
        print('（numpy 一致性检查跳过: %s）' % e)


if __name__ == '__main__':
    main()
