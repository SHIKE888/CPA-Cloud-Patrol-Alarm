#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""vm_fp16.py —— 不做 INT8 量化，直接导出 FP16 模型。

背景（2026-10-16 结论）：小尺寸 pose（384 / 320）做 INT8 量化后，
**类别分支被压成全 0、关键点置信度只剩零星值** —— 即使用两阶段混合量化
把 cv2/cv3/cv4/Concat 都改成 float16 也救不回来，表现是"有框无骨架"。

所以换一条路：干脆不量化（`do_quantization=False` → FP16）。
FP16 没有量化误差，代价是 NPU 吞吐约为 INT8 的一半；但输入面积只有
640 的 36%（384）/ 25%（320），折算下来理论仍比 640 INT8 快：
    384: 0.36 / 0.5 = 0.72  -> 约 1.4x
    320: 0.25 / 0.5 = 0.50  -> 约 2.0x
（只是估算，实测为准 —— 见本仓 bench 脚本）

用法:
    python vm_fp16.py <onnx> <out.rknn> [target]
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import convert_rknn  # noqa: E402,F401  # 触发 onnx.mapping 兼容 shim

from rknn.api import RKNN  # noqa: E402


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    onnx_p, out_p = sys.argv[1], sys.argv[2]
    target = sys.argv[3] if len(sys.argv) > 3 else 'rk3576'

    rknn = RKNN(verbose=False)
    ret = rknn.config(mean_values=[[0, 0, 0]], std_values=[[255, 255, 255]],
                      target_platform=target, optimization_level=3)
    if ret != 0:
        sys.exit('config failed %d' % ret)
    ret = rknn.load_onnx(model=onnx_p)
    if ret != 0:
        sys.exit('load_onnx failed %d' % ret)
    ret = rknn.build(do_quantization=False)          # ★ 不量化 = FP16
    if ret != 0:
        sys.exit('build failed %d' % ret)
    ret = rknn.export_rknn(out_p)
    if ret != 0:
        sys.exit('export failed %d' % ret)
    rknn.release()
    print('OK -> %s  (%.1f MB)' % (out_p, os.path.getsize(out_p) / 1e6))


main()
