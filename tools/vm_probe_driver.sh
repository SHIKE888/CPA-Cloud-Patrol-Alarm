#!/bin/bash
# 对比 guest 内核树里的 milianke_mipi.c 与关键构建信息
SDK="$HOME/mlk-sdk-3576-v1.1.0"
K="$SDK/kernel-6.1"
D="$K/drivers/media/i2c/milianke_mipi.c"

echo "=== 1. 驱动文件基本信息 ==="
ls -la "$D"
md5sum "$D"
echo "--- 行数 ---"
wc -l "$D"

echo
echo "=== 2. 颜色空间相关行 (判断是否已含 REC709 改动) ==="
grep -n -E 'COLORSPACE|colorspace|xfer_func|ycbcr_enc|quantization|SRGB|REC709|BT709|709' "$D" || echo "(无匹配)"

echo
echo "=== 3. 分辨率 / link freq 硬编码 (Phase C 要改的地方) ==="
grep -n -E 'min_width|max_width|min_height|max_height|DUMMY_LINK_FREQ|link_freq|1920|1080' "$D" | head -40

echo
echo "=== 4. 驱动里的模式表/帧率 ==="
grep -n -E 'static const struct|supported_modes|struct v4l2_frmsize|MEDIA_BUS_FMT|data_rate' "$D" | head -30

echo
echo "=== 5. .o 与 boot.img 时间戳 (确认上次编译哪个驱动) ==="
ls -la "$K/drivers/media/i2c/milianke_mipi.o" "$K/arch/arm64/boot/Image" "$K/boot.img" 2>/dev/null

echo
echo "=== 6. defconfig 里的 milianke 项 ==="
grep -n -i 'milianke' "$SDK/device/rockchip/.chips/rk3576/mlk_afh03_rk3576_defconfig" || echo "(defconfig 里没有, 可能在 kernel 片段里)"
echo "--- kernel 片段 ---"
ls "$SDK/device/rockchip/rk3576/" 2>/dev/null | grep -i -E 'kernel|config' | head

echo
echo "=== 7. build.sh 支持的子命令 ==="
"$SDK/build.sh" --help 2>&1 | head -30
