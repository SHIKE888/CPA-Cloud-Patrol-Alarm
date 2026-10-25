#!/bin/sh
# RK3576 ROS 中继端一键部署（Debian 12, root）
# 用法： sh deploy_relay.sh [/root/rk/relay]
# 幂等：重复执行安全；所有被覆盖的原文件都会留 .bak_rosrelay
set -e
SRC=${1:-/root/rk/relay}
STAMP=$(date +%Y%m%d-%H%M%S)

echo "== 0) 归一化换行 =="
for f in "$SRC"/*.conf "$SRC"/*.html "$SRC"/*.sh; do
    [ -f "$f" ] && sed -i 's/\r$//' "$f"
done

echo "== 1) 必要软件包 =="
NEED=""
for p in nginx chrony nftables avahi-daemon; do
    dpkg -s "$p" >/dev/null 2>&1 || NEED="$NEED $p"
done
if [ -n "$NEED" ]; then
    echo "   installing:$NEED"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $NEED
else
    echo "   all present"
fi

echo "== 2) ip_forward =="
echo net.ipv4.ip_forward=1 > /etc/sysctl.d/90-ros-relay.conf
sysctl -q -p /etc/sysctl.d/90-ros-relay.conf
echo "   ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"

echo "== 3) NAT =="
# 实测：本板内核 6.1.99 CONFIG_NF_TABLES 未启用、nat 表不存在（只有 iptables filter 内建）
# → 中继目前做不了 SNAT，车端不能经中继出网。
# 但 nginx 反代是"中继自己发起 TCP 连接"，不需要 NAT/转发，功能不受影响。
if nft list ruleset >/dev/null 2>&1; then
    cp "$SRC/nftables.conf" /etc/nftables.conf
    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl restart nftables && echo "   nftables OK"
else
    echo "   SKIP nftables：内核不支持（NO NF_TABLES / no nat table）"
    echo "   → 车端出网需另行解决（见方案文档「已知限制」）"
fi
iptables-legacy -t nat -S >/dev/null 2>&1 && echo "   legacy nat OK" || echo "   legacy nat 也不可用（预期）"

echo "== 4) chrony（中继做车端 NTP 源） =="
[ -f /etc/chrony/chrony.conf ] && [ ! -f /etc/chrony/chrony.conf.bak_rosrelay ] && cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak_rosrelay
cp "$SRC/chrony-relay.conf" /etc/chrony/chrony.conf
systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony

echo "== 5) nginx 站点 =="
mkdir -p /var/www/ros-relay
cp "$SRC/index.html" /var/www/ros-relay/index.html
cp "$SRC/nginx-ros-relay.conf" /etc/nginx/sites-available/ros-relay
ln -sf /etc/nginx/sites-available/ros-relay /etc/nginx/sites-enabled/ros-relay
if [ -e /etc/nginx/sites-enabled/default ]; then
    mv /etc/nginx/sites-enabled/default /etc/nginx/default.disabled_rosrelay 2>/dev/null || true
fi
# 兜住上一版脚本遗留：留在 sites-enabled 目录里的任何 *default* 都会被 include 通配符吃掉
for f in /etc/nginx/sites-enabled/*default*; do
    [ -e "$f" ] && mv "$f" /etc/nginx/$(basename "$f").moved_rosrelay 2>/dev/null || true
done
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx

echo "== 6) DHCP（车端零配置的关键） =="
if ! dpkg -s dnsmasq >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq || echo "   dnsmasq 安装失败"
fi
cp "$SRC/dnsmasq-ros-relay.conf" /etc/dnsmasq.d/ros-relay.conf
systemctl enable dnsmasq >/dev/null 2>&1 || true
systemctl restart dnsmasq || true
echo "   dnsmasq=$(systemctl is-active dnsmasq)"

echo "== 7) mDNS =="
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true

echo "== 7) 验收 =="
echo "--- end1 ---";  ip -br addr show end1 || true
echo "--- nm ---";    nmcli -g ipv4.method,ipv4.addresses,ipv4.never-default connection show ros-relay-eth || true
echo "--- listen ---"; ss -lntp | grep -E ':(80|8765|9090) ' || echo "  (只有 80 属于中继，8765/9090 在车端)"
echo "--- services ---"
for s in nginx chrony nftables avahi-daemon; do printf '  %-14s %s\n' "$s" "$(systemctl is-active $s)"; done
echo "--- self-test ---"
wget -qO- http://127.0.0.1/relay-health || echo "  health FAILED"
echo
echo "DONE  ($STAMP)"
