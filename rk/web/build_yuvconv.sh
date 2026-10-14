#!/bin/bash
#=============================================================================
# build_yuvconv.sh —— 编译 YUV->BGR 的 C 加速库
#
#   ./build_yuvconv.sh
#
# 产出: 同目录下的 libyuvconv.so, mipi_webstream.py 会自动 ctypes 加载它。
# 若编译失败或 .so 不存在, 服务器会自动退回纯 numpy 版本(慢但结果一致)。
#=============================================================================
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/yuvconv.c"
OUT="$DIR/libyuvconv.so"

if ! command -v gcc >/dev/null 2>&1; then
    echo "找不到 gcc, 无法编译。服务器会继续用 numpy 版本。" >&2
    exit 1
fi

echo "编译 $SRC"
# -O3        最高优化
# -fPIC      位置无关, 供 .so 使用
# -shared    生成动态库
# -funroll-loops / -ftree-vectorize  让编译器尽量用 NEON 向量化
gcc -O3 -fPIC -shared \
    -funroll-loops -ftree-vectorize \
    -Wall -Wextra \
    -o "$OUT" "$SRC" -lm

echo "OK -> $OUT"
ls -l "$OUT"
