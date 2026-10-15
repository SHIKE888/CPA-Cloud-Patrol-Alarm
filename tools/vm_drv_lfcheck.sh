#!/bin/bash
# 确认驱动里 link_freq 的实际取值 (代码 vs 注释)
K=/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1
D=$K/drivers/media/i2c/milianke_mipi.c

echo "=== 菜单 (代码) ==="
grep -n 'link_freq_menu\[\] = ' "$D"
echo
echo "=== 模式表两行 (代码, 第5个字段是 link_freq) ==="
grep -nE '^\s+\{19(20, 1080|20, 1080|, 1080)|^\s+\{3840' "$D"
grep -n 'ULL, .*"1920x1080@60"\|ULL, .*"3840x2160@30"' "$D"
echo
echo "=== 文件里所有 600000000 出现处 (应只在注释里) ==="
grep -n '600000000' "$D"
echo
echo "=== 文件里所有 500000000 出现处 ==="
grep -n '500000000' "$D"
