#!/bin/sh
# 开关双目演示模式, 并打印当前参数
V=${1:-1}
curl -s --max-time 5 -X POST \
     -H 'Content-Type: application/json' \
     -d "{\"dual_demo\":$V}" \
     http://localhost:9012/api/params
echo ""
