#!/bin/sh
# 启动 4K 推流后测真实帧率 + 清空前后的 CSI 错误
BOOT=$(cut -d. -f1 /proc/uptime)
echo "########## 清空 dmesg 环, 便于只看本次 ##########"
dmesg -c > /dev/null 2>&1 && echo "  dmesg 已清" || echo "  dmesg 清空失败(权限?)"

echo ""
echo "########## 启动 4K 推流 ##########"
/usr/local/bin/start.sh 4k
sleep 14

echo ""
echo "########## 端口 / 进程 ##########"
netstat -lntp 2>/dev/null | grep -E "9012|9013"
ps aux 2>/dev/null | grep -E 'webstream' | grep -v grep | head -3

echo ""
echo "########## FPGA 帧计数 -> 实测输入帧率 ##########"
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -iE "帧计数"
sleep 10
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -iE "帧计数"
sleep 10
python3 /root/rk/deploy/fpga_cfg.py dump 2>&1 | grep -iE "帧计数"

echo ""
echo "########## 本次启动后 dmesg (只看新产生的) ##########"
dmesg 2>/dev/null | grep -iE "rkcif|mipi3|csi2|dphy3|milianke|ERR" | tail -40

echo ""
echo "########## 错误计数汇总 ##########"
echo -n "  ECC 错误条数 : "; dmesg 2>/dev/null | grep -c "ecc"
echo -n "  CRC 错误条数 : "; dmesg 2>/dev/null | grep -c "crc"
echo -n "  size/尺寸异常: "; dmesg 2>/dev/null | grep -ciE "size|not enough|overflow"

echo ""
echo "########## 网页数据量 (只报字节数, 不看内容) ##########"
for i in 1 2 3; do
  sz=$(curl -s -m 6 "http://127.0.0.1:9012/snapshot.jpg" 2>/dev/null | wc -c)
  echo "  第${i}次 snapshot.jpg = ${sz} bytes"
done
for i in 1 2 3; do
  sz=$(curl -s -m 6 "http://127.0.0.1:9012/" 2>/dev/null | wc -c)
  echo "  第${i}次 首页 = ${sz} bytes"
done

echo ""
echo "########## web 日志尾部 ##########"
tail -40 /tmp/web_ai.log 2>/dev/null || tail -40 /tmp/web.log 2>/dev/null || echo "  (无日志)"

echo ""
echo "########## 完成 ##########"
