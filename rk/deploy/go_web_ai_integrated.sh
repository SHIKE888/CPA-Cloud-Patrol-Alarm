#!/bin/sh
# 按 docs/ARCHIVE_2026-10-16.md 的正确方式: AI 集成进 9012 (不是独立 9013)
echo "########## 1) 停掉 9013 独立版 (不需要, 白耗 CPU) ##########"
pkill -f start_ai       2>/dev/null && echo "  已停 start_ai"        || echo "  start_ai 未运行"
pkill -f ai_webstream.py 2>/dev/null && echo "  已停 ai_webstream.py" || echo "  ai_webstream 未运行"
sleep 2

echo ""
echo "########## 2) 停旧 9012 ##########"
pkill -f mipi_webstream.py 2>/dev/null && echo "  已停" || echo "  未运行"
sleep 3
echo -n "  残留进程: "; pgrep -af 'mipi_webstream|ai_webstream' | wc -l

echo ""
echo "########## 3) 集成模式重启: AI=1 AI_SRC=ai -> 9012 ##########"
cd /root/rk/web || exit 1
AI=1 AI_SRC=ai nohup bash ./start_webstream.sh /dev/video22 9012 > /tmp/web_ai.log 2>&1 &
sleep 16
echo "--- /tmp/web_ai.log ---"
tail -n 32 /tmp/web_ai.log

echo ""
echo "########## 4) 验证 ##########"
echo "--- 端口 (应只有 9012) ---"
netstat -lntp 2>/dev/null | grep -E "9012|9013" || echo "  (无)"
echo "--- GET /api/ai ---"
curl -s -m 8 http://127.0.0.1:9012/api/ai
echo ""
echo "--- GET / ---"
curl -s -m 6 -o /dev/null -w '  HTTP %{http_code}  %{size_download}B\n' http://127.0.0.1:9012/
echo "--- 进程 ---"
ps aux | grep -E 'mipi_webstream|ai_webstream' | grep -v grep
