#!/bin/bash
# VM 侧：把 ONNX 转成 RK3576 的 RKNN（INT8）
# 运行：bash ~/rknn-work/vm_convert.sh
set -e

PY=~/miniconda3/envs/rknn230/bin/python
W=/home/uisrc/rknn-work
SDK=/home/uisrc/mlk-sdk-3576-v1.1.0/external/rknn-toolkit2
cd "$W"

echo "=== 官方依赖清单（参考）"
cat "$SDK/rknn-toolkit2/packages/x86_64/requirements_cp312-2.3.0.txt" || true

echo "=== 对齐 rknn-toolkit2 2.3.0 的依赖版本"
# onnx>=1.16 删除了 onnx.mapping，rknn-toolkit2 2.3.0 早期 IR 仍会引用它，必须降级
$PY -m pip install -q -i https://pypi.tuna.tsinghua.edu.cn/simple \
    "onnx==1.14.1" "onnxruntime==1.17.3" "setuptools<81" 2>&1 | tail -3 || true

$PY - <<'EOF'
import onnx
print('onnx', onnx.__version__, 'has mapping:', hasattr(onnx, 'mapping'))
EOF

ls calib/*.jpg > dataset.txt
echo "calib: $(wc -l < dataset.txt) images"

echo "=== 转换 检测模型 yolov8n"
$PY convert_rknn.py --onnx ~/models/yolov8n.onnx --out ./yolov8n.rknn \
    --target rk3576 --dtype i8 --dataset dataset.txt 2>&1 | tail -20

echo "=== 转换 姿态模型 yolov8n-pose"
$PY convert_rknn.py --onnx ~/models/yolov8n-pose.onnx --out ./yolov8n-pose.rknn \
    --target rk3576 --dtype i8 --dataset dataset.txt 2>&1 | tail -20

echo "=== 结果"
ls -l ./*.rknn
