#!/bin/sh
echo "########## A) snapshot 是不是实时的 (间隔 4s 取两帧比 md5) ##########"
curl -s -m 8 "http://127.0.0.1:9012/snapshot.jpg" -o /tmp/s1.jpg 2>/dev/null
echo -n "  t0  md5="; md5sum /tmp/s1.jpg 2>/dev/null | cut -d' ' -f1
echo -n "      size="; wc -c < /tmp/s1.jpg 2>/dev/null
sleep 4
curl -s -m 8 "http://127.0.0.1:9012/snapshot.jpg" -o /tmp/s2.jpg 2>/dev/null
echo -n "  t+4 md5="; md5sum /tmp/s2.jpg 2>/dev/null | cut -d' ' -f1
echo -n "      size="; wc -c < /tmp/s2.jpg 2>/dev/null
if cmp -s /tmp/s1.jpg /tmp/s2.jpg; then echo "  => 完全一致: snapshot 是缓存的/不更新"; else echo "  => 有变化: snapshot 是实时更新的"; fi

echo ""
echo "########## B) /api/ai 原始 JSON ##########"
curl -s -m 8 "http://127.0.0.1:9012/api/ai" 2>/dev/null | head -c 600
echo ""

echo ""
echo "########## C) 停 web, 直接测 rkcif 真实收帧速率 ##########"
pkill -f mipi_webstream.py 2>/dev/null && echo "  已停 web" || echo "  web 未运行"
sleep 3
T0=$(date +%s%N)
timeout 25 v4l2-ctl -d /dev/video22 --stream-mmap=4 --stream-count=50 --stream-to=/dev/null > /tmp/v4l.txt 2>&1
RC=$?
T1=$(date +%s%N)
MS=$(( (T1-T0)/1000000 ))
echo "  v4l2-ctl rc=$RC, 50 帧耗时 ${MS} ms"
echo "  v4l2-ctl 输出:"
cat /tmp/v4l.txt 2>/dev/null | sed 's/^/    /'
if [ "$RC" = "0" ]; then
  echo "  ==> 实测收帧速率 = $(awk "BEGIN{printf \"%.3f\", 50*1000/$MS}") fps"
else
  echo "  ==> 没收到 50 帧 (超时或出错), 不能算帧率"
fi

echo ""
echo "########## D) 本次测量期间有没有新的 CSI 错误 ##########"
dmesg 2>/dev/null | grep -iE "ERR|ecc|crc|timeout|overflow" | tail -15
echo -n "  ECC 条数: "; dmesg 2>/dev/null | grep -c "ecc"
echo -n "  CRC 条数: "; dmesg 2>/dev/null | grep -c "crc"

echo ""
echo "########## E) 恢复 web ##########"
/usr/local/bin/start.sh 4k > /tmp/_restart.log 2>&1
tail -12 /tmp/_restart.log
echo ""
echo "########## 完成 ##########"
