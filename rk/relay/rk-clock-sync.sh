#!/bin/sh
# RK3576 中继板自身校时（2026-10-30）
#
# 为什么不是 NTP：
#   板子上 timedatectl 会显示 "NTP service: active"，但 systemd-timesyncd 的
#   D-Bus 服务（org.freedesktop.timesync1）**根本不存在**，实测 `timedatectl
#   timesync-status` 直接报错，所以它从来没有同步过（差了 186 天）。
#   板子能上外网，但装着 chronyd 也没被用起来。
#   这里用最省事的办法：读 HTTP 响应的 Date 头（精度到秒，够用）。
#
# 部署：
#   cp rk-clock-sync.sh /usr/local/bin/rk-clock-sync.sh && chmod +x /usr/local/bin/rk-clock-sync.sh
#   cat > /etc/cron.d/rk-clock <<'EOF'
#   */10 * * * * root /usr/local/bin/rk-clock-sync.sh >> /var/log/rk-clock.log 2>&1
#   @reboot root sleep 20 && /usr/local/bin/rk-clock-sync.sh >> /var/log/rk-clock.log 2>&1
#   EOF
#   chmod 644 /etc/cron.d/rk-clock
#
# 注意：
#   · 时钟偏差大时 HTTPS 会证书报错，所以全部用 http；
#   · 一定要 `hwclock -w` 写 RTC，否则重启又回到老时间；
#   · 校完之后 nginx 的 /time 就是车端的时间源，两边自动对齐。
set -u

for u in http://www.baidu.com \
         http://connect.rom.miui.com/generate_204 \
         http://www.qq.com ; do
    H=$(curl -sI -m 5 "$u" 2>/dev/null | sed -n 's/^[Dd]ate: //p' | tr -d '\r' | head -1)
    [ -n "$H" ] || continue
    T=$(date -u -d "$H" +%s 2>/dev/null) || continue
    [ "$T" -gt 1700000000 ] || continue
    OLD=$(date -u +%s)
    date -u -s "@$T" >/dev/null || exit 1
    hwclock -w 2>/dev/null || true
    echo "[$(date -u +%FT%TZ)] rk clock -> $H (delta $((T - OLD))s, src $u)"
    exit 0
done

echo "rk-clock-sync: 所有时间源都失败"
exit 1
