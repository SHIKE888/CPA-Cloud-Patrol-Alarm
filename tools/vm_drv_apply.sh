#!/bin/bash
# 应用参考版驱动到内核树 + 生成 §3.5 证据快照
BK=$(ls -d /home/uisrc/kernel-backup/*/ 2>/dev/null | tail -1)
K=/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1
REF=/tmp/milianke_mipi.ref.c
DST="$K/drivers/media/i2c/milianke_mipi.c"

echo "=== 0. 前置检查 ==="
if [ ! -f "$REF" ]; then echo "!! 无参考版"; exit 1; fi
md5sum "$BK/files/milianke_mipi.c.orig" "$REF" "$DST"

echo
echo "=== 1. 应用 ==="
cp "$REF" "$DST"
md5sum "$DST"

echo
echo "=== 2. 证据快照 (§3.5) ==="
diff -u "$BK/files/milianke_mipi.c.orig" "$DST" > "$BK/milianke_mipi.c.patch" 2>/dev/null
if [ -f /tmp/norm_diff.txt ]; then
    cp /tmp/norm_diff.txt "$BK/milianke_mipi.c.patch.normalized"
fi
( cd "$K" && md5sum drivers/media/i2c/milianke_mipi.c ) >> "$BK/BASELINE.txt"
echo "已写入: $BK/milianke_mipi.c.patch ($(wc -l < "$BK/milianke_mipi.c.patch") 行)"

echo
echo "=== 3. 内容自检 ==="
echo "  DUMMY_ 残留        : $(grep -c 'DUMMY_' "$DST")   (应为 0)"
echo "  REC709 存在        : $(grep -c 'V4L2_COLORSPACE_REC709' "$DST")   (应为 1)"
echo "  SRGB 残留          : $(grep -c 'V4L2_COLORSPACE_SRGB' "$DST")   (应为 0)"
echo "  模式表条目数       : $(grep -c '^    {[0-9]' "$DST")   (应为 2)"
echo "  link_freq 600MHz   : $(grep -c '600000000' "$DST")"
echo "  3840 存在          : $(grep -c '3840' "$DST")"
echo "  括号平衡 { : $(grep -o '{' "$DST" | wc -l)   } : $(grep -o '}' "$DST" | wc -l)"
echo "  文件行数/字节      : $(wc -l < "$DST") / $(stat -c %s "$DST")"

echo
echo "=== 4. 备份目录 ==="
ls -la "$BK"
