#!/bin/bash
# V21 验证: 新内核 + 新 FPGA bit
echo "=== 1. 内核版本 (期望不再是 #4 Oct 9) ==="
cat /proc/version

echo
echo "=== 2. dmesg: 驱动注册信息 ==="
dmesg | grep -i "milianke MIPI sensor registered" | tail -3
echo "--- 驱动其它消息 ---"
dmesg | grep -i milianke | tail -6

echo
echo "=== 3. 视频节点 ==="
ls -l /dev/video22 2>/dev/null || echo "  !! /dev/video22 不存在"

echo
echo "=== 4. web 服务 ==="
if curl -s -m 5 http://127.0.0.1:9012/api/status; then
    echo
else
    echo "  !! web 未响应"
fi

echo
echo "=== 5. FPGA 关键寄存器 ==="
for a in 0xD4 0xD5 0xE0; do
    printf "  0x%s = " "$(echo $a | tr 'a-f' 'A-F')"
    python3 /root/rk/deploy/fpga_cfg.py get "$a" 2>&1 | tail -1
done
echo "  (0xD4/0xD5 = V21 新增行宽诊断, 低/高字节)"
echo "  (0xE0  = V21 新增 RES_MODE, 0=1080p60 1=4K30)"
echo "  解读: ~966 => 传感器 3864 全像素输出;  ~483 => 传感器 2x2 合并输出"

echo
echo "=== 6. FPGA 全部关键状态 ==="
curl -s -m 5 http://127.0.0.1:9012/api/fpga \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('  status:', d.get('status')); print('  phys  :', d.get('phys'))" 2>&1 | tail -5

echo
echo "=== 7. 抓一帧看是否真实画面 ==="
curl -s -m 8 -o /tmp/v21_snap.jpg http://127.0.0.1:9012/snapshot.jpg && ls -l /tmp/v21_snap.jpg && file /tmp/v21_snap.jpg

echo
echo "=== 8. 重启后 web/FPGA 相关失败日志 ==="
dmesg | grep -iE "error|fail|timeout|mismatch" | grep -iE "milianke|csi|dphy|rkcif" | tail -10 || echo "  (无)"
