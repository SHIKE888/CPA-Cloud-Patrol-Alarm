#!/bin/bash
# 只读检查: 对比内核树原版驱动 与 推到 /tmp 的参考版
# 不修改内核树任何文件
BK=$(ls -d /home/uisrc/kernel-backup/*/ 2>/dev/null | tail -1)
K=/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1
REF=/tmp/milianke_mipi.ref.c
ORIG="$BK/files/milianke_mipi.c.orig"

echo "备份目录: $BK"
if [ ! -f "$ORIG" ]; then
    echo "!! 找不到备份原版: $ORIG"
    exit 1
fi

echo "=== 备份完整性自检 ==="
( cd "$BK/files" && md5sum -c MANIFEST.md5 ) || echo "!! 备份校验失败"

echo
echo "=== 内核树里的驱动现在是什么 (只读) ==="
md5sum "$K/drivers/media/i2c/milianke_mipi.c"

echo
echo "=== 参考版信息 ==="
ls -la --time-style=full-iso "$REF"
md5sum "$REF"
wc -l "$REF" "$ORIG"

echo
echo "=== diff: 内核树原版 -> 参考版 ==="
diff -u "$ORIG" "$REF"
echo "(diff 退出码 $? ; 1 = 有差异, 正常)"

echo
echo "=== 差异行数统计 ==="
echo "  删除行: $(diff "$ORIG" "$REF" | grep -c '^<')"
echo "  新增行: $(diff "$ORIG" "$REF" | grep -c '^>')"
