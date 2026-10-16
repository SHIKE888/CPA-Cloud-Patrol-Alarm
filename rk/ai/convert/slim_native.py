# -*- coding: utf-8 -*-
"""? ultralytics ?? ONNX ?? (1, 4+ncls, N) ?? (1, 5, N) = box4 + person1?"""
import onnx
from onnx import TensorProto, helper

SRC, DST = 'yolov8n-512.onnx', 'yolov8n-slim-512.onnx'
m = onnx.load(SRC)
g = m.graph
o = g.output[0]
n = o.name
dims = [d.dim_value for d in o.type.tensor_type.shape.dim]
names = ['s_' + n, 'e_' + n, 'ax_' + n]
g.initializer.extend([
    helper.make_tensor(names[0], TensorProto.INT64, [1], [0]),
    helper.make_tensor(names[1], TensorProto.INT64, [1], [5]),
    helper.make_tensor(names[2], TensorProto.INT64, [1], [1]),
])
out_name = n + '_slim'
g.node.append(helper.make_node('Slice', [n] + names, [out_name], name='slice_' + n))
del g.output[:]
g.output.extend([helper.make_tensor_value_info(
    out_name, o.type.tensor_type.elem_type, [1, 5, dims[2]])])
try:
    onnx.checker.check_model(m)
except Exception as e:
    print('[warn]', e)
onnx.save(m, DST)
print('SLIM ->', DST, dims, '-> [1,5,%d]' % dims[2])
