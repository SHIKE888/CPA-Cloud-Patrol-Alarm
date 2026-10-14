#!/bin/bash
#=============================================================================
# build_module.sh  —  独立编译 milianke_mipi.ko
#
#   本项目提供 boot.img (内核已内置该驱动)，一般不需要单独编译。
#   仅在以下场景使用本脚本:
#     - 你的内核没有内置 milianke_mipi，想以 .ko 方式加载
#     - 你修改了 milianke_mipi.c，想单独验证
#
# 用法 (在 RK3576 上执行):
#   chmod +x build_module.sh
#   ./build_module.sh          # 编译
#   insmod ./.kbuild/milianke_mipi.ko   # 加载
#   rmmod milianke_mipi                 # 卸载
#
# 依赖: 与运行内核匹配的 kernel headers
#       (/lib/modules/$(uname -r)/build 或 linux-headers-rockchip)
#=============================================================================
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SRC_DIR/.kbuild"
KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"

echo "=============================================================="
echo " 编译 milianke_mipi.ko"
echo " 内核版本 : $KVER"
echo "=============================================================="

# ---- 找 kernel headers ----
if [ ! -f "$KDIR/Makefile" ]; then
    echo ">> 未找到 $KDIR ，尝试建立软链接 ..."
    for cand in "/usr/src/linux-headers-$KVER" \
                "/usr/src/linux-headers-$(echo "$KVER" | awk -F. '{print $1"."$2}')-rockchip" \
                "/usr/src/linux-headers-rockchip"; do
        if [ -f "$cand/Makefile" ]; then
            mkdir -p "/lib/modules/$KVER"
            ln -sfn "$cand" "$KDIR"
            echo "   linked: $KDIR -> $cand"
            break
        fi
    done
fi

if [ ! -f "$KDIR/Makefile" ]; then
    echo "!! 缺少 kernel headers，请先安装，例如:"
    echo "     apt-get update && apt-get install -y linux-headers-rockchip"
    exit 1
fi

# ---- 准备 kbuild 目录 ----
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp "$SRC_DIR/milianke_mipi.c" "$BUILD_DIR/"
cat > "$BUILD_DIR/Makefile" <<'EOF'
obj-m := milianke_mipi.o
EOF

# ---- 编译 ----
make -C "$KDIR" M="$BUILD_DIR" modules

echo ""
echo "=============================================================="
echo " 完成: $BUILD_DIR/milianke_mipi.ko"
echo " 加载: insmod $BUILD_DIR/milianke_mipi.ko"
echo "=============================================================="
