#!/bin/bash
# 精简汇总: 备份状态 + 参考版指纹 + diff 统计
BK=$(ls -d /home/uisrc/kernel-backup/*/ 2>/dev/null | tail -1)
K=/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1
REF=/tmp/milianke_mipi.ref.c
ORIG="$BK/files/milianke_mipi.c.orig"

echo "备份目录 : $BK"
echo
echo "=== 备份目录内容 (tar 是否已完成) ==="
ls -la "$BK" 2>/dev/null
echo
echo "=== 备份完整性校验 ==="
if [ -f "$BK/files/MANIFEST.md5" ]; then
    ( cd "$BK/files" && md5sum -c MANIFEST.md5 )
else
    echo "!! 无 MANIFEST.md5"
fi
echo
echo "=== 内核树里的驱动 (应仍是原版) ==="
md5sum "$K/drivers/media/i2c/milianke_mipi.c"
echo
echo "=== 参考版 ==="
ls -la --time-style=full-iso "$REF" 2>/dev/null || echo "!! /tmp 下没有参考版"
md5sum "$REF" 2>/dev/null
echo
echo "=== diff 统计 (原版 -> 参考版) ==="
if [ -f "$REF" ] && [ -f "$ORIG" ]; then
    echo "  删除行: $(diff "$ORIG" "$REF" | grep -c '^<')"
    echo "  新增行: $(diff "$ORIG" "$REF" | grep -c '^>')"
    echo "  (行号范围:) $(diff "$ORIG" "$REF" | grep -c '^[0-9]')"
else
    echo "!! 文件缺失"
fi
echo
echo "=== tar 进程是否还在跑 ==="
pgrep -a tar || echo "  tar 已结束"
