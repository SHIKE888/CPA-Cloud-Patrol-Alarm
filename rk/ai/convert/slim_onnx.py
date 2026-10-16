#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""slim_onnx.py —— 精简 yolov8 检测 ONNX 的输出，大幅减少 NPU 输出数据量。

背景
    airockchip 版 yolov8n.onnx 每个尺度输出三个张量：
        DFL(64ch) + 类别(80ch) + 辅助(1ch)
    640x640 下 3 个尺度加起来是 3*(64+80+1)*6400 ≈ 435 个 "通道-像素"，
    rknnlite 每次推理都要把这些 int8 反量化成 float32 再拷给 Python —— 约 11MB/帧。
    实测 det 单次 29.5ms，远超 NPU 算力本身（同模型官方 640 约 10ms），
    大头就花在输出搬运上。

做法
    只保留 person 一个类（丢掉其余 79 类）并删掉辅助输出：
        3*(64+1)*6400 ≈ 195   -> 约 5MB/帧
    解码逻辑完全兼容（后处理里 keep_cls=[0] 本来就是只取 person）。

用法（VM/PC，需要 onnx）
    python slim_onnx.py --in yolov8n.onnx --out yolov8n-slim.onnx --cls 0
"""
from __future__ import annotations

import argparse
import sys

import onnx
from onnx import TensorProto, helper


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", required=True)
    ap.add_argument("--cls", type=int, default=0, help="保留的类别索引(默认 0=person)")
    ap.add_argument("--keep-aux", action="store_true", help="保留 1 通道的辅助输出")
    a = ap.parse_args()

    m = onnx.load(a.src)
    g = m.graph

    kept, dropped = [], []
    nodes = list(g.node)
    new_outputs = []

    for o in g.output:
        dims = [d.dim_value for d in o.type.tensor_type.shape.dim]
        if len(dims) == 4 and dims[1] > 1 and dims[1] != 64:
            # 类别头（80 类）：切片成 1 类
            n = o.name
            s_name, e_name, ax_name = "s_" + n, "e_" + n, "ax_" + n
            g.initializer.extend([
                helper.make_tensor(s_name, TensorProto.INT64, [1], [a.cls]),
                helper.make_tensor(e_name, TensorProto.INT64, [1], [a.cls + 1]),
                helper.make_tensor(ax_name, TensorProto.INT64, [1], [1]),
            ])
            out_name = n + "_person"
            nodes.append(helper.make_node(
                "Slice", [n, s_name, e_name, ax_name], [out_name], name="slice_" + n))
            new_outputs.append(helper.make_tensor_value_info(
                out_name, o.type.tensor_type.elem_type, [1, 1, dims[2], dims[3]]))
            kept.append("%s(1,%d,%d,%d) -> %s(1,1,%d,%d)"
                        % (n, dims[1], dims[2], dims[3], out_name, dims[2], dims[3]))
        elif len(dims) == 4 and dims[1] == 1 and not a.keep_aux:
            dropped.append("%s(1,1,%d,%d)" % (o.name, dims[2], dims[3]))
        else:
            new_outputs.append(o)

    del g.output[:]
    g.output.extend(new_outputs)
    del g.node[:]
    g.node.extend(nodes)

    try:
        onnx.checker.check_model(m)
    except Exception as e:  # noqa: BLE001
        print("[warn] onnx.checker: %s" % e, file=sys.stderr)

    onnx.save(m, a.dst)
    print("裁剪后的输出：")
    for k in kept:
        print("  + " + k)
    for d in dropped:
        print("  - " + d)
    print("saved -> %s" % a.dst)


if __name__ == "__main__":
    main()
