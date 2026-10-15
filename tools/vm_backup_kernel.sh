#!/bin/bash
# ============================================================================
# 内核改动前的回溯备份 (在虚拟机 uisrc@192.168.65.128 上运行)
#   用法:  powershell -ExecutionPolicy Bypass -File tools\vmsh.ps1 -File tools\vm_backup_kernel.sh
#   产物:  /home/uisrc/kernel-backup/<时间戳>/
#   配套:  tools/vm_restore_kernel.sh  (回滚)
# 注意:  本脚本只读源文件 + 写备份目录, 不修改内核树本身。
# ============================================================================
set -e

SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
K="$SDK/kernel-6.1"
DRV="$K/drivers/media/i2c/milianke_mipi.c"
STOCK_MD5=15931acbe1f7f12332101a33ed9b2d20     # 未改动的 stock 驱动
GOOD_BOOT_MD5=0deb3ac78d3ce5861b847f31d88e9414 # 板上现役 boot.img

BK="$HOME/kernel-backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK/files"
echo "备份目录: $BK"
echo

# ---------- 0) 基线记录 ----------
echo "== [0/4] 记录基线 =="
{
    echo "date: $(date -Is)"
    echo "host: $(hostname)  kernel: $(uname -r)"
    echo
    echo "--- md5 ---"
    md5sum "$DRV" "$K/boot.img"
    echo
    echo "--- mtime ---"
    ls -la --time-style=full-iso "$DRV" "$K/boot.img"
    echo
    echo "--- 产物时间线 ---"
    ls -la --time-style=full-iso "$K/arch/arm64/boot/Image" "$K/arch/arm64/boot/Image.lz4" \
        "$K/resource.img" "$K/vmlinux" "$K/drivers/media/i2c/milianke_mipi.o" 2>/dev/null || true
} | tee "$BK/BASELINE.txt"
echo

# 基线自检: 驱动必须是 stock, boot.img 必须是板上现役那份
CUR_DRV_MD5=$(md5sum "$DRV" | cut -d' ' -f1)
CUR_BOOT_MD5=$(md5sum "$K/boot.img" | cut -d' ' -f1)
if [ "$CUR_DRV_MD5" != "$STOCK_MD5" ]; then
    echo "!! 警告: 驱动已不是 stock (现在是 $CUR_DRV_MD5, 期望 $STOCK_MD5)"
    echo "!! 说明内核树已被人改过, 请先确认状态再决定是否继续。"
fi
if [ "$CUR_BOOT_MD5" != "$GOOD_BOOT_MD5" ]; then
    echo "!! 警告: kernel-6.1/boot.img 与板上现役镜像不一致 (现在是 $CUR_BOOT_MD5)"
fi

# ---------- 1) 逐文件原样副本 + 清单 ----------
echo "== [1/4] 备份被改文件 =="
cp -a "$DRV" "$BK/files/milianke_mipi.c.orig"
( cd "$BK/files" && md5sum milianke_mipi.c.orig > MANIFEST.md5 && cat MANIFEST.md5 )
echo

# ---------- 2) 全树源码归档 (排除编译产物) ----------
echo "== [2/4] 归档内核源码树 (约 2.0 GB, 需要一会儿) =="
tar -czf "$BK/kernel-6.1-src.tgz" -C "$SDK" \
    --exclude='*.o' --exclude='*.a' --exclude='*.cmd' --exclude='*.ko' \
    --exclude='*.mod' --exclude='*.mod.*' --exclude='modules.*' --exclude='.tmp_*' \
    kernel-6.1
sha256sum "$BK/kernel-6.1-src.tgz" | tee "$BK/kernel-6.1-src.tgz.sha256"
ls -la "$BK/kernel-6.1-src.tgz"
echo

# ---------- 3) 现役可回刷镜像 + 配置 ----------
echo "== [3/4] 备份 boot.img 与 .config =="
cp -a "$K/boot.img" "$BK/boot.img.known-good"
cp -a "$K/.config" "$BK/.config.before"
md5sum "$BK/boot.img.known-good"     # 期望 $GOOD_BOOT_MD5
echo

# ---------- 4) 提示板上分区 dump (需在 Windows 侧做) ----------
echo "== [4/4] 完成 =="
echo "还剩一步要在 Windows 上做 (板上分区字节级 dump, 回滚最后一道保险):"
echo '  ssh afc03 "dd if=/dev/disk/by-partlabel/boot of=/root/boot.dump-$(date +%Y%m%d).img bs=1M count=64 conv=fsync; md5sum /root/boot.dump-*.img"'
echo
echo "回滚: tools/vm_restore_kernel.sh $BK"
