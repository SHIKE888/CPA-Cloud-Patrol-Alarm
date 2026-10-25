# -*- coding: utf-8 -*-
"""ONNX -> RKNN（在 VM 上跑，环境 rknn-toolkit2 2.3.0）。

    conda activate rknn230
    python convert_action_rknn.py --onnx action_net.onnx --data ./data --out action_net.rknn

为什么这个模型特别适合转 RKNN
-----------------------------
* 全部算子只有 MatMul / Conv / BN / ReLU / GlobalAvgPool / Gemm，
  没有 Gather/ScatterND/自定义图算子 —— 这类模型在 rknn-toolkit2 上基本一次过。
* 输入已经是归一化浮点 (1,32,17,3)，mean/std 用单位阵即可，不需要任何
  图像预处理，量化误差来源少。
* 整网 ~30 MFLOPs，INT8 量化对精度的影响远小于大模型；如果量化后掉点，
  直接 `--no-quant`（FP16）也能跑，这个体量 FP16 一样是亚毫秒级。

⚠ 量化校准集必须用**板上真实采集**的骨架（record_action.py 的产物），
  不能用随机数 —— 随机的分布和真实分布差太远，量化 scale 会偏。
"""
import argparse
import glob
import os

import numpy as np


class SeqDataset(object):
    """量化校准用的数据集：返回 [[seq[None]]]（rknn 要求 list of inputs）。"""

    def __init__(self, data_dir, limit=300, t_len=32, v=17, c=3):
        files = sorted(glob.glob(os.path.join(data_dir, '**', '*.npz'), recursive=True))
        if not files:
            raise SystemExit('校准集为空：%s 下没有 npz' % data_dir)
        if len(files) > limit:
            step = len(files) / float(limit)
            files = [files[int(i * step)] for i in range(limit)]
        self.items = []
        for fp in files:
            try:
                seq = np.asarray(np.load(fp, allow_pickle=True)['seq'], np.float32)
            except Exception:                              # noqa: BLE001
                continue
            if seq.shape != (t_len, v, c):
                continue
            self.items.append(seq)
        if not self.items:
            raise SystemExit('校准集里没有形状为 (%d,%d,%d) 的样本' % (t_len, v, c))
        print('校准样本 %d 段' % len(self.items))

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        return [self.items[i][None]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--onnx', default='action_net.onnx')
    ap.add_argument('--tflite', default='',
                    help='用 TFLite 输入（TF 训练路的产物）；给了就不看 --onnx')
    ap.add_argument('--out', default='action_net.rknn')
    ap.add_argument('--data', default='./data', help='量化校准集目录')
    ap.add_argument('--target', default='rk3576')
    ap.add_argument('--no-quant', action='store_true', help='不量化(FP16)，精度最稳')
    ap.add_argument('--t-len', type=int, default=32)
    args = ap.parse_args()

    from rknn.api import RKNN                          # noqa: WPS433

    rknn = RKNN(verbose=False)
    # 输入已经是零均值、按框高归一化的骨架坐标，不做任何额外缩放
    rknn.config(mean_values=[[0, 0, 0]],
                std_values=[[1, 1, 1]],
                target_platform=args.target,
                optimization_level=3,
                quantized_algorithm='normal',
                quantized_method='channel')

    if args.tflite:
        print('--> load_tflite %s' % args.tflite)
        if rknn.load_tflite(model=args.tflite) != 0:
            raise SystemExit('load_tflite 失败')
    else:
        print('--> load_onnx %s' % args.onnx)
        if rknn.load_onnx(model=args.onnx, inputs=['kps'],
                          input_size_list=[[1, args.t_len, 17, 3]]) != 0:
            raise SystemExit('load_onnx 失败')

    print('--> build (%s)' % ('FP16' if args.no_quant else 'INT8'))
    if args.no_quant:
        if rknn.build(do_quantization=False) != 0:
            raise SystemExit('build 失败')
    else:
        ds = SeqDataset(args.data, t_len=args.t_len)
        if rknn.build(do_quantization=True, dataset=ds) != 0:
            raise SystemExit('build 失败（多半是校准集不够或分布不对）')

    print('--> export_rknn')
    if rknn.export_rknn(args.out) != 0:
        raise SystemExit('export_rknn 失败')
    print('OK ->', args.out, '(%.1f KB)' % (os.path.getsize(args.out) / 1024.0))


if __name__ == '__main__':
    main()
