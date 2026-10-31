#!/bin/sh
# =============================================================================
# install_board.sh —— 在 RK3576 板卡上安装 cloud-agent（幂等）
#
#   sh install_board.sh <token> [server_url]
#   sh install_board.sh abc123... http://<SERVER_DOMAIN>
#
# 依赖：板端 /usr/bin/python3（3.8+，只用标准库）。不需要 cv2：
#       缩图由 9012 的 /snapshot.jpg?w= 在板端用 cv2 完成。
# =============================================================================
set -eu

TOKEN="${1:-}"
SERVER="${2:-${CSI_SERVER:-}}"
DIR=/root/rk/cloud
SRC=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
[ -n "$TOKEN" ] || { echo "用法: sh install_board.sh <token> [server_url]"; exit 1; }
# 服务器地址不写死在仓库里，必须由调用方给出（第 2 个参数或 CSI_SERVER）
[ -n "$SERVER" ] || { echo "缺少 server_url：请传第 2 个参数，或设置 CSI_SERVER=http(s)://<SERVER_DOMAIN>"; exit 1; }
[ -f "$SRC/cloud_agent.py" ] || { echo "缺少 cloud_agent.py"; exit 1; }

mkdir -p "$DIR"
install -m 0755 "$SRC/cloud_agent.py" "$DIR/cloud_agent.py"
printf '%s' "$TOKEN" >"$DIR/token"
chmod 600 "$DIR/token"

cat >/etc/systemd/system/cloud-agent.service <<EOF
[Unit]
Description=CSI2RK cloud agent (uplink + command poll)
# 顺序：WiFi 模块 → NetworkManager → wait-online → mipi-webstream → 本代理
After=network-online.target mipi-webstream.service
Wants=network-online.target mipi-webstream.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u $DIR/cloud_agent.py --server $SERVER --token-file $DIR/token --local http://127.0.0.1:9012 --node afc03 --name "AFC03 IMX415" --interval 5
Restart=always
RestartSec=5
MemoryMax=64M
CPUQuota=10%
Nice=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cloud-agent

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloud-agent >/dev/null 2>&1 || true
systemctl restart cloud-agent
sleep 2

echo "--- 连通性 ---"
curl -s --max-time 6 "$SERVER/api/ping" || echo "  !! 无法访问 $SERVER"
echo
echo "--- 状态 ---"
systemctl --no-pager --lines=6 status cloud-agent || true
