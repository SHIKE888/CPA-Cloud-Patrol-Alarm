#!/bin/sh
# 把 SD 卡做成"致命错误专用日志盘", 同时彻底关掉 CSI2 刷屏日志
set -e

echo "=== [1/6] 格式化 SD 卡 (mmcblk1p1) ==="
if blkid /dev/mmcblk1p1 >/dev/null 2>&1; then
  echo "  已有文件系统, 跳过格式化"
else
  mkfs.ext4 -F -L SDLOG /dev/mmcblk1p1 >/dev/null
  echo "  已格式化为 ext4 (LABEL=SDLOG)"
fi

echo "=== [2/6] 挂载到 /mnt/sd ==="
mkdir -p /mnt/sd
grep -q 'SDLOG' /etc/fstab || \
  echo 'LABEL=SDLOG /mnt/sd ext4 defaults,noatime,nofail 0 2' >> /etc/fstab
mountpoint -q /mnt/sd || mount /mnt/sd
mkdir -p /mnt/sd/log
df -h /mnt/sd | tail -1

echo "=== [3/6] 抑制内核刷屏 (持久化) ==="
echo 'kernel.printk = 1 4 1 7' > /etc/sysctl.d/99-quiet-kernel.conf
sysctl -p /etc/sysctl.d/99-quiet-kernel.conf >/dev/null
dmesg -n 1

echo "=== [4/6] rsyslog: 丢掉刷屏, 致命写 SD ==="
cat > /etc/rsyslog.d/10-fatal-sd.conf <<'EOF'
# ---- 刷屏源: 直接丢弃 (CSI2 ECC 错误每帧刷屏, 曾把 14G 磁盘写满) ----
:msg, contains, "MIPI_CSI2 ERR"            stop
:msg, contains, "vblank need >="           stop
:msg, contains, "csi size err"             stop
:msg, contains, "csi2-dphy"                stop

# ---- 内核 info/notice/warning 不落盘 (dmesg 里仍可查) ----
kern.info;kern.notice;kern.warning         stop

# ---- 致命级别单独存到 SD 卡 ----
kern.emerg;kern.alert;kern.crit            /mnt/sd/log/kernel-fatal.log
& stop
EOF

echo "=== [5/6] 日志大小上限 ==="
cat > /etc/logrotate.d/sd-fatal <<'EOF'
/mnt/sd/log/kernel-fatal.log {
    size 5M
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
EOF
cat > /etc/logrotate.d/syslog-size <<'EOF'
/var/log/syslog {
    size 20M
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
EOF

echo "=== [6/6] 重启 rsyslog ==="
truncate -s 0 /var/log/syslog
systemctl restart rsyslog || true
sleep 2
systemctl is-active rsyslog

echo "--- 验证: 等 8 秒看 syslog 是否还在涨 ---"
a=$(stat -c %s /var/log/syslog)
sleep 8
b=$(stat -c %s /var/log/syslog)
echo "syslog: $a -> $b 字节"
echo "kern.log 大小: $(ls -lh /var/log/kern.log 2>/dev/null | awk '{print $5}')"
echo "SD 日志: $(ls -lh /mnt/sd/log/ 2>/dev/null | tail -2)"
df -h / | tail -1
