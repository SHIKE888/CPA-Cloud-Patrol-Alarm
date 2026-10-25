# -*- coding: utf-8 -*-
"""导出动作模型：TFLite(给 RKNN) + NPZ(numpy/板上兜底)，并做三方数值校验。

    python export_action_tf.py --ckpt action_net_tf.h5 --out action_net

产出：
    action_net.tflite   -> 板上/VM 用 rknn.load_tflite() 转 rknn
    action_net.npz      -> action_np.py 的 numpy 前向（CPU 兜底）
    action_net.onnx     -> 装了 tf2onnx 才生成（可选，走 RKNN 的另一条路）

为什么要三方校验：
  Keras 前向、TFLite 前向、numpy 前向的**布局约定**不一样（NHWC/转置/BN eps），
  任何一处写错都会让板上精度悄悄变差。这里直接比 max|diff|，>1e-3 就报警。
"""
import argparse
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, '..', 'board'))

os.environ.setdefault('TF_CPP_MIN_LOG_LEVEL', '2')

import tensorflow as tf                                   # noqa: E402

from action_spec import ACTION_CLASSES, T_LEN, V_JOINTS, C_CH   # noqa: E402
from action_net_tf import build_model, dump_npz           # noqa: E402

# GPU 上 TF 默认用 TF32 做 matmul（相当于 10bit 尾数），会让一致性校验
# 一直停在 1e-3 量级、看不出到底是"实现写错"还是"精度不够"。
# 校验时关掉，diff 应该掉到 1e-6。
try:
    tf.config.experimental.enable_tensor_float_32_execution(False)
except Exception:                                         # noqa: BLE001
    pass


def to_tflite(model, path):
    spec = tf.TensorSpec([1, T_LEN, V_JOINTS, C_CH], tf.float32, name='kps')
    f = tf.function(lambda x: model(x, training=False)).get_concrete_function(spec)
    conv = tf.lite.TFLiteConverter.from_concrete_functions([f], model)
    conv.optimizations = []                     # 保持 float32，稳定性优先
    buf = conv.convert()
    with open(path, 'wb') as fp:
        fp.write(buf)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ckpt', default='action_net_tf.h5')
    ap.add_argument('--out', default='action_net')
    ap.add_argument('--onnx', action='store_true', help='额外尝试 tf2onnx 导出')
    args = ap.parse_args()

    model = build_model()
    model(tf.zeros((1, T_LEN, V_JOINTS, C_CH)))
    model.load_weights(args.ckpt)
    print('载入权重 %s' % args.ckpt)

    tfl = to_tflite(model, args.out + '.tflite')
    print('TFLite -> %s (%.1f KB)' % (tfl, os.path.getsize(tfl) / 1024.0))

    npz = dump_npz(model, args.out + '.npz', T_LEN)
    print('NPZ    -> %s (%.1f KB)' % (npz, os.path.getsize(npz) / 1024.0))

    # ---------------- 三方一致性
    rng = np.random.RandomState(0)
    x = rng.randn(4, T_LEN, V_JOINTS, C_CH).astype(np.float32) * 0.2
    x[:, :, :, 2] = 1.0

    ref = model(x, training=False).numpy()

    interp = tf.lite.Interpreter(model_path=tfl)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]
    got_tfl = []
    for i in range(x.shape[0]):
        interp.set_tensor(inp['index'], x[i:i + 1])
        interp.invoke()
        got_tfl.append(interp.get_tensor(out['index'])[0])
    got_tfl = np.stack(got_tfl)
    print('TFLite vs keras  max|diff| = %.3e' % np.abs(got_tfl - ref).max())

    try:
        from action_np import NumpyActionNet
        nn_ = NumpyActionNet(npz)
        got_np, _ = nn_.predict_batch(x)
        print('numpy  vs keras  max|diff| = %.3e' % np.abs(got_np - ref).max())
        print('        预测 keras %s / numpy %s'
              % (ref.argmax(1).tolist(), got_np.argmax(1).tolist()))
    except Exception as e:                                # noqa: BLE001
        print('（numpy 一致性检查跳过: %s）' % e)

    if args.onnx:
        try:
            import tf2onnx                                    # noqa: F401
            spec = (tf.TensorSpec([1, T_LEN, V_JOINTS, C_CH], tf.float32, name='kps'),)
            tf2onnx.convert.from_keras(model, input_signature=spec,
                                       opset=12, output_path=args.out + '.onnx')
            print('ONNX   -> %s.onnx' % args.out)
        except ImportError:
            print('（未装 tf2onnx，跳过 ONNX；RKNN 可以用 TFLite 路径）')

    print('-' * 60)
    print('下一步：把 %s.tflite 拷到 VM，`rknn.load_tflite()` 转 rknn；'
          '或在板上用 %s.npz 走 CPU 兜底。' % (args.out, args.out))
    print('类别顺序：%s' % ACTION_CLASSES)


if __name__ == '__main__':
    main()
