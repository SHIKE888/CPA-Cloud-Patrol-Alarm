#!/bin/bash
# 忽略空白差异的审计: 证明 原版->参考版 除有意改动外只差空白
BK=$(ls -d /home/uisrc/kernel-backup/*/ 2>/dev/null | tail -1)
ORIG="$BK/files/milianke_mipi.c.orig"
REF=/tmp/milianke_mipi.ref.c
OUT=/tmp/drv_diff_w.txt

echo "=== 1. 原始 diff (含空白) 统计 ==="
echo "  hunk 数     : $(diff "$ORIG" "$REF" | grep -c '^[0-9]')"
echo "  删除行      : $(diff "$ORIG" "$REF" | grep -c '^<')"
echo "  新增行      : $(diff "$ORIG" "$REF" | grep -c '^>')"

echo
echo "=== 2. 忽略所有空白后的 diff 统计 (这才是真实语义改动) ==="
diff -u -w "$ORIG" "$REF" > "$OUT"
echo "  hunk 数     : $(grep -c '^@@' "$OUT")"
echo "  删除行      : $(grep -c '^-' "$OUT")"
echo "  新增行      : $(grep -c '^+' "$OUT")"
echo "  输出文件    : $OUT"

echo
echo "=== 3. 行尾/文件属性 ==="
file "$ORIG" "$REF"
echo "  ORIG: $(tr -d '[:space:]' < "$ORIG" | wc -c) 个非空白字符"
echo "  REF : $(tr -d '[:space:]' < "$REF" | wc -c) 个非空白字符"

echo
echo "=== 4. 只看被修改的既有行 (非纯新增/纯删除, 即 - 和 + 配对出现的部分) ==="
grep '^-' "$OUT" | grep -v '^---' | grep -v '^-[[:space:]]*$' \
  | sed 's/[[:space:]]//g' | sort > /tmp/only_del.txt
grep '^+' "$OUT" | grep -v '^+++' | grep -v '^+[[:space:]]*$' \
  | sed 's/[[:space:]]//g' | sort > /tmp/only_add.txt
echo "  忽略空白后, 老代码里存在的行数 : $(wc -l < /tmp/only_del.txt)"
echo "  忽略空白后, 新代码里存在的行数 : $(wc -l < /tmp/only_add.txt)"
echo "  两边都存在的行 (即未改动)      : $(comm -12 /tmp/only_del.txt /tmp/only_add.txt | wc -l)"
echo
echo "  --- 被删掉且新版本里没有的原有行 (每行表示确实被替换/删除了) ---"
comm -23 /tmp/only_del.txt /tmp/only_add.txt | head -40
