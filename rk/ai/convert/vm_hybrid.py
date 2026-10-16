#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""vm_hybrid.py —— 两阶段混合量化（解决 yolov8-pose 关键点置信度被 INT8 压成 0 的问题）。

用法（VM 上）：
  # 1) 生成量化配置
  python vm_hybrid.py step1 --onnx yolov8n-pose.onnx --dataset dataset.txt --target rk3576
  # 2) 按正则把关键点相关层改成 float16（自动改 cfg）
  python vm_hybrid.py patch --cfg yolov8n-pose.quantization.cfg --match "Concat_6|kpt|Sigmoid"
  #   也可用 --list 只打印 cfg 中出现的层名
  # 3) 用改好的配置导出
  python vm_hybrid.py step2 --model yolov8n-pose.model --data yolov8n-pose.data \
      --cfg yolov8n-pose.quantization.cfg --out yolov8n-pose-hybrid.rknn
"""
from __future__ import annotations

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import convert_rknn  # noqa: E402,F401  # 触发 onnx.mapping 兼容 shim

from rknn.api import RKNN  # noqa: E402


def do_step1(a):
    rknn = RKNN(verbose=False)
    ret = rknn.config(mean_values=[[0, 0, 0]], std_values=[[255, 255, 255]],
                      target_platform=a.target, optimization_level=3)
    if ret != 0:
        sys.exit('config failed %d' % ret)
    ret = rknn.load_onnx(model=a.onnx)
    if ret != 0:
        sys.exit('load_onnx failed %d' % ret)
    ret = rknn.hybrid_quantization_step1(dataset=a.dataset)
    if ret != 0:
        sys.exit('hybrid_quantization_step1 failed %d' % ret)
    rknn.release()
    print('step1 完成，已生成 *.quantization.cfg / *.model / *.data')


def do_step2(a):
    rknn = RKNN(verbose=False)
    ret = rknn.hybrid_quantization_step2(model_input=a.model,
                                         data_input=a.data,
                                         model_quantization_cfg=a.cfg)
    if ret != 0:
        sys.exit('hybrid_quantization_step2 failed %d' % ret)
    ret = rknn.export_rknn(a.out)
    if ret != 0:
        sys.exit('export failed %d' % ret)
    rknn.release()
    print('OK -> %s (%.2f MB)' % (a.out, os.path.getsize(a.out) / 1048576.0))


def _cfg_layer_names(text):
    """把 cfg 里出现的候选层名抠出来（custom_quantize_layers 段 + quantize_parameters 键）。"""
    names = []
    m = re.search(r'^custom_quantize_layers:\s*(.*)$', text, re.M)
    if m and m.group(1).strip() not in ('{}', ''):
        pass
    # quantize_parameters 下的缩进键
    in_qp = False
    for line in text.splitlines():
        if line.startswith('quantize_parameters'):
            in_qp = True
            continue
        if in_qp and line and not line.startswith(' '):
            in_qp = False
        if in_qp and line.startswith('  ') and line.rstrip().endswith(':'):
            names.append(line.strip()[:-1])
    return names


def do_list(a):
    text = open(a.cfg, encoding='utf-8').read()
    names = _cfg_layer_names(text)
    print('cfg 内共 %d 个可配置层：' % len(names))
    pat = re.compile(a.match) if a.match else None
    for n in names:
        hit = '  <== 命中' if (pat and pat.search(n)) else ''
        print('  %s%s' % (n, hit))
    print('\n--- custom_quantize_layers 原始内容 ---')
    m = re.search(r'^custom_quantize_layers:.*?$', text, re.M)
    print(m.group(0) if m else '(未找到)')


def do_patch(a):
    """把匹配的层改为指定 dtype（写入 custom_quantize_layers）。"""
    text = open(a.cfg, encoding='utf-8').read()
    names = _cfg_layer_names(text)
    pat = re.compile(a.match) if a.match else None
    picked = [n for n in names if pat and pat.search(n)]
    if not picked:
        print('没有层匹配 %r，未修改' % a.match)
        return
    block = 'custom_quantize_layers:\n'
    for n in picked:
        block += '  %s: %s\n' % (n, a.dtype)
    new, cnt = re.subn(r'^custom_quantize_layers:.*?$', block.rstrip('\n'), text,
                       count=1, flags=re.M)
    if cnt == 0:
        new = text + '\n' + block
    if a.backup:
        open(a.cfg + '.bak', 'w', encoding='utf-8').write(text)
    open(a.cfg, 'w', encoding='utf-8').write(new)
    print('已把 %d 个层设为 %s：' % (len(picked), a.dtype))
    for n in picked:
        print('  %s' % n)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)

    s1 = sub.add_parser('step1')
    s1.add_argument('--onnx', required=True)
    s1.add_argument('--dataset', required=True)
    s1.add_argument('--target', default='rk3576')
    s1.set_defaults(func=do_step1)

    s2 = sub.add_parser('step2')
    s2.add_argument('--model', required=True)
    s2.add_argument('--data', required=True)
    s2.add_argument('--cfg', required=True)
    s2.add_argument('--out', required=True)
    s2.set_defaults(func=do_step2)

    for name, fn in (('list', do_list), ('patch', do_patch)):
        sp = sub.add_parser(name)
        sp.add_argument('--cfg', required=True)
        sp.add_argument('--match', default='')
        sp.add_argument('--dtype', default='float16')
        sp.add_argument('--backup', action='store_true')
        sp.set_defaults(func=fn)

    a = ap.parse_args()
    a.func(a)


if __name__ == '__main__':
    main()
