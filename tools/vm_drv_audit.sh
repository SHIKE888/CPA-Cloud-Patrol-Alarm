#!/bin/bash
# 严格审计: 按行把连续空白折叠成单个空格再 diff
# 这样"纯缩进/行尾差异"会消失, 只留下真正的语义差异
BK=$(ls -d /home/uisrc/kernel-backup/*/ 2>/dev/null | tail -1)
ORIG="$BK/files/milianke_mipi.c.orig"
REF=/tmp/milianke_mipi.ref.c

# 去 BOM + 去 CR + 折叠行内空白
sed 's/\r$//; s/^\xef\xbb\xbf//; s/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//' "$ORIG" > /tmp/n_orig.txt
sed 's/\r$//; s/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//' "$REF" > /tmp/n_ref.txt

echo "=== 归一化后行数 ==="
wc -l /tmp/n_orig.txt /tmp/n_ref.txt

echo
echo "=== 归一化后的 diff 统计 (应只剩本次有意改动) ==="
diff -u /tmp/n_orig.txt /tmp/n_ref.txt > /tmp/norm_diff.txt
echo "  hunk 数 : $(grep -c '^@@' /tmp/norm_diff.txt)"
echo "  删除行  : $(grep -c '^-[^-]' /tmp/norm_diff.txt)"
echo "  新增行  : $(grep -c '^+[^+]' /tmp/norm_diff.txt)"
echo
echo "=== 被删除(即被替换/移除)的原有代码行 ==="
grep '^-[^-]' /tmp/norm_diff.txt
