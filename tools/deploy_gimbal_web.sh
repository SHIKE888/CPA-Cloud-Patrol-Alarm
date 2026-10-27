#!/bin/bash
# 部署「云台页签」相关文件到板端（不重启服务、不发任何运动指令）。
#
# 先在 PC 上：
#   scp rk/web/gimbal_web.py rk/web/mipi_webstream.py \
#       tools/patch_ai_overlay_frame.py tools/deploy_gimbal_web.sh afc03:/tmp/gz_deploy/
#   ssh afc03 "bash /tmp/gz_deploy/deploy_gimbal_web.sh"
#
# 之后由人决定何时 `systemctl restart mipi-webstream`（重启不会动云台：
# 串口是收到第一条动作请求时才会打开）。
set -e
WEB=${WEB:-/root/rk/web}
SRC=${SRC:-/tmp/gz_deploy}
TS=$(date +%Y%m%d_%H%M%S)

echo "=== 备份到 $WEB/_bak ==="
mkdir -p "$WEB/_bak"
for f in mipi_webstream.py ai_overlay.py; do
    [ -f "$WEB/$f" ] && cp -f "$WEB/$f" "$WEB/_bak/$f.bak_$TS" && echo "  $f -> _bak/$f.bak_$TS"
done

echo "=== 安装 ==="
cp -f "$SRC/mipi_webstream.py" "$WEB/mipi_webstream.py"
cp -f "$SRC/gimbal_web.py"     "$WEB/gimbal_web.py"
chmod 644 "$WEB/gimbal_web.py" "$WEB/mipi_webstream.py"

echo "=== 补 ai_overlay.py 的 frame 字段（只打这一处，不覆盖整文件）==="
python3 "$SRC/patch_ai_overlay_frame.py" "$WEB/ai_overlay.py"

echo "=== 语法检查 ==="
python3 -m py_compile "$WEB/mipi_webstream.py" "$WEB/gimbal_web.py" "$WEB/ai_overlay.py"
echo "  compile OK"

echo "=== 结果 ==="
ls -l "$WEB/gimbal_web.py" "$WEB/mipi_webstream.py" "$WEB/ai_overlay.py"
echo
echo "下一步（需要人工决定，会中断推流约 10 s，但不会动云台）："
echo "  systemctl restart mipi-webstream && sleep 9 && curl -s http://127.0.0.1:9012/api/gimbal"
