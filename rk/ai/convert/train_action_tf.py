# -*- coding: utf-8 -*-
"""训练轻量骨架动作模型 —— **TensorFlow 版**（本机 tf_gpu 环境直接跑）。

    conda activate tf_gpu      # 或直接指定 python.exe
    python train_action_tf.py --data ./data --epochs 120 --out action_net_tf.h5
    python train_action_tf.py --synthetic --epochs 5        # 验证链路

数据来自板上的 `record_action.py`（每类一个目录的 npz）。
采集要求见 docs/ACTION_MODEL.md —— `idle` 一定要采最多、且包含误报源。
"""
import argparse
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

os.environ.setdefault('TF_CPP_MIN_LOG_LEVEL', '2')

import tensorflow as tf                                  # noqa: E402

from action_spec import ACTION_CLASSES, T_LEN, V_JOINTS, C_CH   # noqa: E402
from action_data import (load_dataset, make_synthetic, augment,   # noqa: E402
                         split_stratified, class_weights)
from action_net_tf import build_model                     # noqa: E402

NC = len(ACTION_CLASSES)


def make_train_ds(X, y, w, batch, aug, seed):
    """无限增强数据集，yield (x, label, sample_weight)。"""
    def gen():
        rng = np.random.RandomState(seed)
        order = np.arange(len(y))
        while True:
            rng.shuffle(order)
            for i in order:
                yield (augment(X[i], rng, aug) if aug > 0 else X[i],
                       np.int32(y[i]), np.float32(w[i]))
    out = tf.data.Dataset.from_generator(
        gen,
        output_signature=(tf.TensorSpec([T_LEN, V_JOINTS, C_CH], tf.float32),
                          tf.TensorSpec([], tf.int32),
                          tf.TensorSpec([], tf.float32)))
    return out.batch(batch).prefetch(tf.data.AUTOTUNE)


def make_eval_ds(X, y, batch):
    ds = tf.data.Dataset.from_tensor_slices((X.astype(np.float32),
                                            y.astype(np.int32)))
    return ds.batch(batch)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default='')
    ap.add_argument('--synthetic', action='store_true')
    ap.add_argument('--epochs', type=int, default=80)
    ap.add_argument('--batch', type=int, default=64)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--val', type=float, default=0.15)
    ap.add_argument('--aug', type=float, default=1.0)
    ap.add_argument('--out', default='action_net_tf.h5')
    ap.add_argument('--seed', type=int, default=0)
    args = ap.parse_args()

    tf.random.set_seed(args.seed)
    np.random.seed(args.seed)

    if args.synthetic or not args.data:
        if not args.synthetic:
            print('未给 --data，自动进入 --synthetic 模式')
        X, y = make_synthetic()
    else:
        X, y = load_dataset(args.data)

    tr, va = split_stratified(y, args.val, args.seed)
    w_all = class_weights(y, tr)
    print('训练 %d / 验证 %d   类别权重 %s'
          % (len(tr), len(va), np.round(w_all, 2).tolist()))

    ds_tr = make_train_ds(X[tr], y[tr], w_all[y[tr]], args.batch, args.aug, args.seed)
    ds_va = make_eval_ds(X[va], y[va], args.batch)
    steps = int(np.ceil(len(tr) / float(args.batch)))

    model = build_model()
    model(tf.zeros((1, T_LEN, V_JOINTS, C_CH)))
    model.compile(optimizer=tf.keras.optimizers.Adam(args.lr),
                  loss=tf.keras.losses.SparseCategoricalCrossentropy(from_logits=True),
                  metrics=['accuracy'])

    # 最优权重存成 HDF5（save_weights_only=True）；若存 TF checkpoint
    # 格式（默认），后面 model.load_weights() 会报 py_checkpoint_reader 错误。
    ckpt = args.out + '.best.h5'
    cbs = [
        tf.keras.callbacks.ModelCheckpoint(ckpt, monitor='val_accuracy',
                                           save_best_only=True,
                                           save_weights_only=True, verbose=0),
        tf.keras.callbacks.ReduceLROnPlateau(monitor='val_accuracy', factor=0.5,
                                             patience=8, min_lr=1e-5, verbose=1),
    ]
    model.fit(ds_tr, epochs=args.epochs, steps_per_epoch=steps,
              validation_data=ds_va, callbacks=cbs, verbose=2)

    # 用最优权重评估 + 混淆矩阵
    model.load_weights(ckpt)
    conf = np.zeros((NC, NC), np.int64)
    for xb, yb in ds_va:
        pred = model(xb, training=False).numpy().argmax(1)
        for t_, p_ in zip(yb.numpy().tolist(), pred.tolist()):
            conf[t_, p_] += 1
    acc = np.trace(conf) / max(1, conf.sum())
    # 子类化模型不能 save 成 HDF5 整模型（Keras 限制），只存权重即可 ——
    # 导出脚本会用 build_model() 重建结构再 load_weights()。
    model.save_weights(args.out)
    print('-' * 62)
    print('验证准确率 %.3f   已保存 %s' % (acc, args.out))
    print('混淆矩阵（行=真实, 列=预测）')
    print('        ' + ' '.join('%5s' % c[:5] for c in ACTION_CLASSES))
    for i, c in enumerate(ACTION_CLASSES):
        print('%7s ' % c[:7] + ' '.join('%5d' % v for v in conf[i]))


if __name__ == '__main__':
    main()
