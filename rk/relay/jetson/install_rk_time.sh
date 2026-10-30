#!/bin/bash
# 车端「上电自动校时」安装脚本 —— 时间源 = RK3576 中继板（nginx 的 /time 端点）
#
# 背景（2026-10-30）：
#   · 车端 RTC 没电池，断电后时间会跳回去（实测是 2024-06-26，慢 858 天）；
#   · 车端**没有外网**，也没有可用的 NTP 同步，所以 systemd-timesyncd 一直
#     "actived but not synchronized"，靠它自己永远校不上；
#   · 车端和板子之间那条 RTL8153 链路（192.168.100.0/24）是通的，
#     板子 nginx 现在提供一个 `GET /time` 返回 unix 时间（秒.毫秒）。
#
# 为什么要 root / 本脚本做什么：
#   改系统时钟需要 CAP_SYS_TIME，普通用户做不到。这里把特权收窄到最小：
#     1) /usr/local/bin/rk-time-sync       —— 唯一一个需要 root 的动作
#     2) /etc/sudoers.d/50-rk-time         —— 只对这个文件放开 NOPASSWD
#     3) /etc/cron.d/rk-time               —— 开机 30s 后 + 每 5 分钟各校一次
#   装完之后：**上电即自动对齐板子时间**，不需要任何人操作。
#
# 用法（车上一次，会问一次 sudo 密码）：
#   bash ~/ros_relay/install_rk_time.sh
#
# 换时间源： RK_TIME_URL=http://192.168.100.2/time bash ~/ros_relay/install_rk_time.sh
set -u
SRC=${RK_TIME_URL:-http://192.168.100.2/time}

echo "== 0/4 先确认能取到板子时间 =="
PROBE=$(curl -s -m 4 "$SRC" || true)
case "$PROBE" in
  ''|*[!0-9.]*) echo "✖ 取不到时间: $SRC （返回 '$PROBE'）"; echo "  先确认板子在 192.168.100.2、nginx 有 /time"; exit 1;;
esac
echo "  板子时间 = $PROBE  (本机现在 = $(date -u +%s))"

echo "== 1/4 安装 root 侧校时脚本 /usr/local/bin/rk-time-sync =="
sudo tee /usr/local/bin/rk-time-sync >/dev/null <<EOF
#!/bin/sh
# 从 RK3576 中继板取 unix 时间并设置系统时钟（顺带写 RTC）。
# 这是唯一需要 root 的动作，sudo 规则里只放开了这个文件。
URL=\${RK_TIME_URL:-$SRC}
TS=\$(curl -s -m 3 "\$URL" | cut -d. -f1)
case "\$TS" in ''|*[!0-9]*) echo "rk-time: 取不到时间 (\$URL)"; exit 1;; esac
[ "\$TS" -gt 1700000000 ] || { echo "rk-time: 时间不合理 \$TS"; exit 1; }
NOW=\$(date -u +%s); D=\$((TS - NOW)); [ \$D -lt 0 ] && D=\$((0 - D))
[ \$D -le 2 ] && exit 0
date -u -s "@\$TS" >/dev/null && hwclock -w 2>/dev/null
echo "rk-time: 校时完成 偏差 \${D}s -> \$(date '+%F %T %Z')"
EOF
sudo chmod 755 /usr/local/bin/rk-time-sync || exit 1

echo "== 2/4 放开免密 sudo（只针对上面这一个脚本） =="
sudo tee /etc/sudoers.d/50-rk-time >/dev/null <<'EOF'
# 车端校时专用：只允许 wheeltec 免密跑这一个脚本，不放开其它任何东西
wheeltec ALL=(root) NOPASSWD: /usr/local/bin/rk-time-sync
EOF
sudo chmod 440 /etc/sudoers.d/50-rk-time
if sudo visudo -c -f /etc/sudoers.d/50-rk-time >/dev/null 2>&1; then
  echo "  sudoers 语法 OK"
else
  sudo rm -f /etc/sudoers.d/50-rk-time
  echo "✖ sudoers 语法有问题，已回滚" ; exit 1
fi

echo "== 3/4 安装 root cron（开机 + 每 5 分钟） =="
sudo tee /etc/cron.d/rk-time >/dev/null <<'EOF'
SHELL=/bin/sh
# 车端校时：开机 30 秒后一次，之后每 5 分钟一次（RTC 无电池，时间会跳回去）
@reboot root sleep 30 && /usr/local/bin/rk-time-sync >> /var/log/rk-time.log 2>&1
*/5 * * * * root /usr/local/bin/rk-time-sync >> /var/log/rk-time.log 2>&1
EOF
sudo chmod 644 /etc/cron.d/rk-time
echo "  已写入 /etc/cron.d/rk-time"

echo "== 4/4 立即校一次 =="
sudo -n /usr/local/bin/rk-time-sync || sudo /usr/local/bin/rk-time-sync

echo
echo "完成。现在车里时间： $(date)"
echo "以后再偏了看日志： tail /var/log/rk-time.log"
