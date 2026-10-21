#!/bin/bash
#=============================================================================
#  fix_boot_order.sh —— 把开机自启理顺成一条明确的上电链（幂等，可反复跑）
#
#  目标顺序：
#    sysinit / wifibt-init
#      → load-drv（insmod AIC8800 WiFi/BT 模块）
#      → NetworkManager → NetworkManager-wait-online（等到真联网，≤25s）
#      → mipi-webstream（FPGA 复位 + media 通路 + :9012 推流/AI）
#          └ boot_start.sh 末尾会叫一次 `start.sh cloud`（幂等）
#      → cloud-agent（长轮询上行；systemd 侧也声明 After=mipi-webstream）
#
#  背景：
#    * NetworkManager-wait-online 在出厂镜像里被 mask 成 /dev/null，
#      于是 cloud-agent 的 After=network-online.target 等于没等 ——
#      开机瞬间 WiFi 还没 DHCP 完，代理先失败几轮（能自愈但日志难看）。
#    * load-drv 原来只挂在 multi-user.target，可能晚于 NetworkManager。
#
#  用法:  bash fix_boot_order.sh          # 改完 reboot 验证
#         bash fix_boot_order.sh --check  # 只看现状
#=============================================================================
set -u

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }

mk_override() {   # $1=单元名(不带 .service)  $2=文件名  $3=内容
    mkdir -p "/etc/systemd/system/$1.service.d"
    printf '%s\n' "$3" > "/etc/systemd/system/$1.service.d/$2"
}

show() {
    echo "--- 启用状态 ---"
    systemctl is-enabled load-drv.service NetworkManager.service \
        NetworkManager-wait-online.service mipi-webstream.service \
        cloud-agent.service ssh.service 2>&1
    echo "--- 关键顺序（mipi-webstream 之前应启动的） ---"
    systemctl list-dependencies --after mipi-webstream.service --no-pager 2>/dev/null | head -12
}

if [ "${1:-}" = "--check" ]; then
    show
    exit 0
fi

echo "[1/5] load-drv: WiFi 模块先于 NetworkManager"
mk_override load-drv 10-before-nm.conf '[Unit]
Before=NetworkManager.service'

echo "[2/5] NetworkManager-wait-online: 解除 mask 并启用（25s 超时兜底）"
systemctl unmask NetworkManager-wait-online.service >/dev/null 2>&1 || true
mk_override NetworkManager-wait-online timeout.conf '[Service]
ExecStart=
ExecStart=/usr/bin/nm-online -s -q --timeout=25'
systemctl enable NetworkManager-wait-online.service >/dev/null 2>&1 || true

echo "[3/5] cloud-agent: 等网络 + 等推流服务"
mk_override cloud-agent 10-order.conf '[Unit]
After=network-online.target mipi-webstream.service
Wants=network-online.target mipi-webstream.service'

echo "[4/5] mipi-webstream: 明确等网络栈（本机 9012 不依赖外网，只是排序好看）"
mk_override mipi-webstream 10-order.conf '[Unit]
After=network.target NetworkManager.service
Wants=network.target'

echo "[5/5] 确保 core 服务都是 enabled"
systemctl enable load-drv.service NetworkManager.service \
    mipi-webstream.service cloud-agent.service ssh.service >/dev/null 2>&1 || true

systemctl daemon-reload
echo
show
echo
echo "下一步: reboot 后验证 —— start.sh status / curl http://<SERVER_DOMAIN>/api/ping"
