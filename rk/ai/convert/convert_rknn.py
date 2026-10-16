#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ONNX -> RKNN 转换（RK3576 / INT8），需在装有 rknn-toolkit2 的 Linux x86_64 上运行。

模型来源：
  yolov8n.onnx       airockchip/rknn_model_zoo  examples/yolov8/model      （COCO 80 类，person=0）
  yolov8n-pose.onnx  airockchip/rknn_model_zoo  examples/yolov8_pose/model （单类 person + 17 关键点）

用法：
  python convert_rknn.py --onnx yolov8n.onnx --out yolov8n.rknn --target rk3576 --dtype i8 --dataset dataset.txt
"""
import argparse
import os
import sys


def _patch_onnx_mapping():
    """兼容 shim：onnx>=1.16 删除了 onnx.mapping，而 rknn-toolkit2 2.3.0 仍在用它。

    py3.12 只能装 onnx>=1.16（更早版本没有 cp312 wheel），所以这里手工补回映射表。
    """
    try:
        import types

        import numpy as np
        import onnx
    except ImportError:
        return
    if hasattr(onnx, 'mapping'):
        return
    t2n = {
        1: np.dtype('float32'), 2: np.dtype('uint8'), 3: np.dtype('int8'),
        4: np.dtype('uint16'), 5: np.dtype('int16'), 6: np.dtype('int32'),
        7: np.dtype('int64'), 8: np.dtype('object'), 9: np.dtype('bool'),
        10: np.dtype('float16'), 11: np.dtype('float64'), 12: np.dtype('uint32'),
        13: np.dtype('uint64'), 14: np.dtype('complex64'),
        15: np.dtype('complex128'), 16: np.dtype('float16'),
    }
    m = types.ModuleType('onnx.mapping')
    m.TENSOR_TYPE_TO_NP_TYPE = t2n
    m.NP_TYPE_TO_TENSOR_TYPE = dict((v, k) for k, v in t2n.items())
    onnx.mapping = m
    sys.modules['onnx.mapping'] = m
    print('[shim] 已补回 onnx.mapping（onnx %s）' % getattr(onnx, '__version__', '?'))


_patch_onnx_mapping()


def show_io(path):
    """打印 ONNX 的输入/输出张量形状，便于核对后处理实现。"""
    try:
        import onnx
    except ImportError:
        print('[warn] onnx 未安装，跳过 IO 打印')
        return

    m = onnx.load(path)

    def shp(t):
        dims = []
        for d in t.type.tensor_type.shape.dim:
            dims.append(d.dim_value if d.dim_value else (d.dim_param or '?'))
        return dims

    print('[onnx] input :', [(i.name, shp(i)) for i in m.graph.input])
    print('[onnx] output:', [(o.name, shp(o)) for o in m.graph.output])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--onnx', required=True, help='输入 onnx 路径')
    ap.add_argument('--out', required=True, help='输出 rknn 路径')
    ap.add_argument('--target', default='rk3576', help='NPU 平台，如 rk3576')
    ap.add_argument('--dtype', default='i8', choices=['i8', 'fp'], help='i8=量化, fp=浮点')
    ap.add_argument('--dataset', default='', help='量化校准集 txt（每行一个图片路径）')
    ap.add_argument('--no-mean-std', action='store_true',
                    help='不使用 mean/std 归一化（模型自带）')
    args = ap.parse_args()

    if not os.path.isfile(args.onnx):
        sys.exit('找不到 onnx: %s' % args.onnx)

    show_io(args.onnx)

    from rknn.api import RKNN

    rknn = RKNN(verbose=False)

    # yolov8 系列：输入为 0~255 的 uint8，模型内部需要 (x/255)
    # 因此 mean=0, std=255，喂图时给 RGB uint8 NHWC 即可。
    print('--> config')
    if args.no_mean_std:
        ret = rknn.config(target_platform=args.target)
    else:
        ret = rknn.config(mean_values=[[0, 0, 0]],
                          std_values=[[255, 255, 255]],
                          target_platform=args.target,
                          optimization_level=3)
    if ret != 0:
        sys.exit('config failed: %d' % ret)
    print('    done')

    print('--> load_onnx')
    ret = rknn.load_onnx(model=args.onnx)
    if ret != 0:
        sys.exit('load_onnx failed: %d' % ret)
    print('    done')

    print('--> build  (do_quantization=%s)' % (args.dtype == 'i8'))
    dataset = args.dataset or None
    if args.dtype == 'i8' and not dataset:
        sys.exit('i8 量化必须提供 --dataset（校准图片列表）')
    ret = rknn.build(do_quantization=(args.dtype == 'i8'), dataset=dataset)
    if ret != 0:
        sys.exit('build failed: %d' % ret)
    print('    done')

    print('--> export_rknn')
    ret = rknn.export_rknn(args.out)
    if ret != 0:
        sys.exit('export failed: %d' % ret)
    rknn.release()
    print('OK -> %s  (%.2f MB)' % (args.out, os.path.getsize(args.out) / 1048576.0))


if __name__ == '__main__':
    main()
