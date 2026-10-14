#!/bin/bash
# i2c_probe.sh —— 确认 RK 与 FPGA 之间的 I2C 是否真的可用
#
# 关心的点:
#   1) FPGA 在 dts 里声明为 i2c9 上的 0x1a (milianke,fpga-virtual)
#   2) 它到底会不会 ACK? 如果 0x1a 不在 i2cdetect 列表里, 说明 FPGA 侧
#      并没有实现 I2C 从机 —— 那样"用 I2C 改参数"就需要先在 FPGA 里加一个从机
#   3) 总线上一共有哪些设备 (摄像头应该在 0x36 附近)

echo "=== I2C 总线列表 ==="
i2cdetect -l 2>/dev/null || echo "  (没有 i2cdetect, 试试 apt install i2c-tools)"

echo
echo "=== sysfs 里已注册的 i2c 设备 ==="
ls -1 /sys/bus/i2c/devices/ 2>/dev/null | head -40

echo
echo "=== 9-001a (FPGA 虚拟节点) ==="
ls -1 /sys/bus/i2c/devices/9-001a/ 2>/dev/null || echo "  不存在"

echo
echo "=== 逐个总线扫描 (找 FPGA/摄像头) ==="
for b in $(i2cdetect -l 2>/dev/null | awk '{print $1}' | sed 's/i2c-//'); do
    echo "--- i2c-$b ---"
    i2cdetect -y -r "$b" 2>/dev/null | tail -n +2
done

echo
echo "=== 尝试从 0x1a 读一个字节 ==="
if i2cget -y 9 0x1a 0x00 2>&1; then
    echo "  ^ 有应答 -> FPGA 实现了 I2C 从机"
else
    echo "  ^ 无应答 -> FPGA 目前不是 I2C 从机"
fi

echo
echo "=== dmesg 里 i2c / milianke 相关 ==="
dmesg 2>/dev/null | grep -iE 'i2c|milianke' | tail -20

echo
echo "=== 驱动对 0x1a 的注册情况 ==="
cat /sys/bus/i2c/devices/9-001a/name 2>/dev/null
cat /sys/bus/i2c/devices/9-001a/modalias 2>/dev/null
