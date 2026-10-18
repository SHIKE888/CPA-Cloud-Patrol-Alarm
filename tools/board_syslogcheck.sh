#!/bin/sh
# 统计 syslog 尾部刷屏来源
echo "=== syslog 大小 ==="
ls -lh /var/log/syslog
echo "=== 尾部 20 行 ==="
tail -20 /var/log/syslog
echo "=== 尾部出现最多的关键字 ==="
tail -c 400000 /var/log/syslog | tr ':' '\n' | sed 's/^ *//' | sort | uniq -c | sort -rn | head -12
