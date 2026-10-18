#!/bin/sh
# 让 systemd-journald:
#   1) 只保存 crit 及以上 (致命) 级别
#   2) 数据目录放到 SD 卡 (/mnt/sd/journal, 通过 bind mount)
# rsyslog 那边只负责“丢掉刷屏”, 不再承担重要日志。
set -e

echo "=== [1/5] SD 上的 journal 目录 ==="
mkdir -p /mnt/sd/journal
if [ -f /etc/fstab ] && ! grep -q '/var/log/journal' /etc/fstab; then
  echo '/mnt/sd/journal /var/log/journal none bind,nofail 0 0' >> /etc/fstab
  echo "  已写入 fstab"
fi
mountpoint -q /var/log/journal || {
  cp -a /var/log/journal/. /mnt/sd/journal/ 2>/dev/null || true
  mount --bind /mnt/sd/journal /var/log/journal
}
mountpoint /var/log/journal

echo "=== [2/5] journald 只存致命级别 ==="
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-fatal-sd.conf <<'EOF'
[Journal]
Storage=persistent
# 只保存 crit(2) 及以上: emerg / alert / crit
MaxLevelStore=crit
MaxLevelSyslog=crit
MaxLevelKMsg=crit
SystemMaxUse=200M
SystemMaxFileSize=20M
EOF

echo "=== [3/5] 重启 journald ==="
systemctl restart systemd-journald
sleep 2
systemctl is-active systemd-journald

echo "=== [4/5] 空间占用 ==="
journalctl --disk-usage 2>/dev/null

echo "=== [5/5] 验证: 写一条 crit, 看落在哪 ==="
echo '<2>SDTEST crit after journald reconfig' > /dev/kmsg
sleep 2
journalctl -p crit -n 2 --no-pager 2>/dev/null | tail -3
echo "--- SD 目录 ---"
ls -lh /mnt/sd/journal/ 2>/dev/null | tail -3
df -h /mnt/sd / | tail -2
