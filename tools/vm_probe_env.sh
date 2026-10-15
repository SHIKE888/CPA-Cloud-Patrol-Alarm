#!/bin/bash
# 探查虚拟机里的内核源码 / 工具链 / 共享目录 位置
echo "=== 1. 主目录 ==="
ls -la "$HOME" 2>/dev/null | head -40

echo
echo "=== 2. 内核源码候选 (<=4 层, 带 Makefile 的 linux 树) ==="
for base in "$HOME" /opt /data /work /srv /mnt; do
    [ -d "$base" ] || continue
    find "$base" -maxdepth 4 -type d \
        \( -iname "linux-*" -o -iname "*kernel*" -o -iname "rk3576*" -o -iname "*rk35*" \) \
        2>/dev/null | head -20
done

echo
echo "=== 3. 认哪个是真内核树 (有 .config 或 arch/arm64) ==="
find "$HOME" /opt /data /work -maxdepth 5 -type f -name "Makefile" -path "*/linux-*" 2>/dev/null | head -10

echo
echo "=== 4. 交叉工具链 ==="
which aarch64-linux-gnu-gcc aarch64-none-linux-gnu-gcc 2>/dev/null
ls -d /opt/*toolchain* /opt/*gcc* "$HOME"/*toolchain* "$HOME"/gcc* 2>/dev/null | head -20
echo "--- PATH 里已有的 aarch64 ---"
echo "$PATH" | tr ':' '\n' | grep -i -E 'gcc|tool|aarch' | head -10

echo
echo "=== 5. 共享目录 (宿主机 F:\\Project Files\\FPGA\\03_MLK_AFH03_AFC03) ==="
ls /mnt/hgfs/ 2>/dev/null
ls -la /mnt/hgfs/MLK_AFH03_AFC03 2>/dev/null | head -15

echo
echo "=== 6. 本项目相关文件是否已在 guest 里 ==="
find "$HOME" /mnt/hgfs -maxdepth 5 -iname "milianke_mipi.c" 2>/dev/null | head -10
find "$HOME" -maxdepth 4 -iname "boot.img" 2>/dev/null | head -10

echo
echo "=== 7. 磁盘空间 ==="
df -h "$HOME" 2>/dev/null | head -5
