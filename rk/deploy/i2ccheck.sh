#!/bin/sh
# i2ccheck.sh —— 确认 RK 侧 I2C9 是否启用、总线上有什么
echo "--- 板型 model ---"
cat /proc/device-tree/model 2>/dev/null; echo
echo
echo "--- I2C 控制器状态 (只列 okay 的) ---"
for d in /proc/device-tree/soc/i2c@*; do
    [ -e "$d" ] || continue
    s=$(tr -d '\0' < "$d/status" 2>/dev/null)
    n=$(basename "$d")
    [ "$s" = "okay" ] && echo "  $n  status=$s"
done
echo
echo "--- /dev/i2c-* ---"
ls /dev/i2c-* 2>/dev/null || echo "  (无)"
echo
echo "--- 设备树里有没有 fpga@* 节点 ---"
find /proc/device-tree -maxdepth 5 -name 'fpga@*' 2>/dev/null || echo "  (无)"
echo
echo "--- i2c 工具 ---"
for t in i2cdetect i2cget i2cset i2ctransfer; do
    command -v $t >/dev/null 2>&1 && echo "  有 $t" || echo "  无 $t"
done
echo
echo "--- 扫描 /dev/i2c-9 (RK 的 I2C9) ---"
if command -v i2cdetect >/dev/null 2>&1 && [ -e /dev/i2c-9 ]; then
    i2cdetect -y -r 9 2>&1 | head -12
else
    echo "  (缺 i2cdetect 或 /dev/i2c-9)"
fi
echo
echo "--- 全部总线快扫 (看哪条有 0x1a / 0x40) ---"
if command -v i2cdetect >/dev/null 2>&1; then
    for n in $(ls /dev/i2c-* 2>/dev/null | sed 's#.*/i2c-##'); do
        out=$(i2cdetect -y -r $n 2>/dev/null | grep -E '1a|40' )
        [ -n "$out" ] && { echo "  i2c-$n:"; echo "$out" | sed 's/^/    /'; }
    done
fi
