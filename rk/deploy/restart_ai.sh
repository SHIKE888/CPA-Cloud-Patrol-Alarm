#!/bin/sh
# 重启 AI 标注服务并验证推理真的在跑
pkill -f ai_webstream.py 2>/dev/null && echo "  杀掉旧 AI" || echo "  无旧 AI"
sleep 2
cd /root/rk/ai || exit 1
SRC=http://127.0.0.1:9012/stream PORT=9013 bash board/start_ai.sh 2>&1 | tail -20
echo ""
echo "=== 日志 (找 [infer] 异常) ==="
tail -12 /root/rk/ai/ai_webstream_9013.log
echo ""
echo "=== 等 12 秒后看状态 JSON ==="
sleep 12
curl -s -m 6 http://127.0.0.1:9013/api/status
echo ""
echo "=== 端口 ==="
netstat -lntp 2>/dev/null | grep -E "9012|9013"
