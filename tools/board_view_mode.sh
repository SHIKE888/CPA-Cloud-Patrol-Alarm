#!/bin/sh
# 切换推流模式: 0=单目全屏  1=双目拼接  2=双目演示(复制一路)
case "$1" in
  0) D=0; DEMO=0; TXT="单目全屏" ;;
  1) D=1; DEMO=0; TXT="双目拼接(左cam0/右cam1)" ;;
  2) D=1; DEMO=1; TXT="双目演示(复制一路, 假数据)" ;;
  *) echo "usage: $0 0|1|2"; exit 1 ;;
esac
echo "-> $TXT"
curl -s --max-time 5 -X POST \
     -H 'Content-Type: application/json' \
     -d "{\"dual\":$D,\"dual_demo\":$DEMO}" \
     http://localhost:9012/api/params
echo ""
sleep 2
echo -n "  实际输出: "
curl -s --max-time 5 localhost:9012/api/status \
  | tr ',' '\n' | grep -E '"width"|"height"|"fps"' | tr '\n' ' '
echo ""
