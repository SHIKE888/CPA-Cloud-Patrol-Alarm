#!/bin/sh
# =============================================================================
# install.sh —— 在云服务器上安装 CSI2RK 云端看板（幂等，可重复执行）
#
#   sh install.sh                 # 默认站点根目录 /www/wwwroot/csi-dashboard
#   SITE_ROOT=/www/wwwroot/xxx sh install.sh
#
# 只做四件事：
#   1) /opt/csi-dashboard/{server.py,data}      后端（单文件，无依赖）
#   2) $SITE_ROOT/index.html                    看板页面（nginx 直接静态服务）
#   3) /etc/systemd/system/csi-dashboard.service
#   4) 生成 config.json（token / 看板密码，已存在则保留）
#
# 不装 pip 包、不建 venv、不写数据库。卸载见 README 末尾。
# =============================================================================
set -eu

PREFIX=/opt/csi-dashboard
SITE_ROOT="${SITE_ROOT:-/www/wwwroot/csi-dashboard}"
SRC=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
command -v python3 >/dev/null || { echo "缺少 python3"; exit 1; }
[ -f "$SRC/server.py" ] || { echo "缺少 server.py（需与本脚本同目录）"; exit 1; }
[ -f "$SRC/index.html" ] || { echo "缺少 index.html（需与本脚本同目录）"; exit 1; }
[ -d "$SITE_ROOT" ] || { echo "站点目录不存在: $SITE_ROOT"; exit 1; }

# --- 运行用户（不给 home、不给 shell）---
if ! getent passwd csidash >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin csidash
    echo "已创建系统用户 csidash"
fi

# --- 目录 ---
mkdir -p "$PREFIX/data/shots"
install -m 0755 "$SRC/server.py" "$PREFIX/server.py"
install -m 0644 "$SRC/index.html" "$SITE_ROOT/index.html"
chown -R csidash:csidash "$PREFIX/data"
chmod 700 "$PREFIX/data"

# --- 配置（首次生成 token 与看板密码，之后不动）---
CFG="$PREFIX/config.json"
if [ ! -f "$CFG" ]; then
    TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
    cat >"$CFG" <<EOF
{
  "host": "127.0.0.1",
  "port": 9080,
  "data_dir": "$PREFIX/data",
  "static_dir": "$SITE_ROOT",
  "token": "$TOKEN",
  "ui_user": "admin",
  "ui_pass": "$PASS",
  "offline_sec": 30,
  "alarm_hold_sec": 180,
  "dedupe_sec": 6,
  "max_shots": 100,
  "max_shot_mb": 20,
  "max_alarm_kb": 600
}
EOF
    NEWCFG=1
else
    NEWCFG=0
fi
chown csidash:csidash "$CFG"
chmod 600 "$CFG"

# --- systemd ---
cat >/etc/systemd/system/csi-dashboard.service <<'EOF'
[Unit]
Description=CSI2RK cloud dashboard
After=network.target

[Service]
Type=simple
User=csidash
Group=csidash
WorkingDirectory=/opt/csi-dashboard
ExecStart=/usr/bin/python3 -u /opt/csi-dashboard/server.py --config /opt/csi-dashboard/config.json
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/csi-dashboard/data
MemoryMax=96M
CPUQuota=25%
LimitNOFILE=256
StandardOutput=journal
StandardError=journal
SyslogIdentifier=csi-dashboard

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable csi-dashboard >/dev/null 2>&1 || true
systemctl restart csi-dashboard
sleep 1.2

echo "-------------------------------------------------------------"
systemctl --no-pager --lines=0 status csi-dashboard | head -4 || true
echo "自检:"
curl -s --max-time 3 http://127.0.0.1:9080/api/ping || echo "  !! 后端未响应"
echo
if [ "$NEWCFG" = "1" ]; then
    echo "板端 token : $(python3 -c "import json;print(json.load(open('$CFG'))['token'])")"
    echo "看板密码   : admin / $(python3 -c "import json;print(json.load(open('$CFG'))['ui_pass'])")"
    echo "（改密码：编辑 $CFG 后 systemctl restart csi-dashboard）"
else
    echo "沿用已有配置: $CFG"
fi
echo "下一步：把 /api/ 反向代理到 127.0.0.1:9080（见 deploy/nginx-snippet.conf）"
echo "-------------------------------------------------------------"
