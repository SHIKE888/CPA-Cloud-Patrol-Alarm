#!/bin/sh
# V54l/V54m (0x540A) 验证: 合并器输出 JPEG 起始三态判读
BUS=9; ADR=0x40

rg() { i2cget -y $BUS $ADR $(printf '0x%02x' $1) 2>/dev/null || echo 0xff; }

echo "=== 版本 ==="
v9=$(rg 0xA9); vA=$(rg 0xAA)
VER=$(( vA * 256 + v9 ))
echo "  0xA9=$v9 0xAA=$vA  -> 0x$(printf '%04X' $VER)"
if [ "$v9" != "0x0a" ] || [ "$vA" != "0x54" ]; then
    echo "  !! 不是 0x540A, 后面的判读无意义"
fi

echo
echo "=== 帧计数 / 字节数 (连读 6 次看趋势) ==="
for i in 1 2 3 4 5 6; do
    b0=$(rg 0xA0); b1=$(rg 0xA1); b2=$(rg 0xA2)
    f0=$(rg 0xD0)
    bytes=$(( (b2<<16) | (b1<<8) | b0 ))
    echo "  t$i: bytes=$bytes  frames=0x$f0"
    sleep 1
done

echo
echo "=== V54l 三态诊断 ==="
CC=$(rg 0xCC); CD=$(rg 0xCD); CE=$(rg 0xCE)
echo "  0xCC 首字节 = $CC   (正常必须是 0xff)"
echo "  0xCD 次字节 = $CD   (正常必须是 0xd8)"
echo "  0xCE SOI见过= $CE   (正常 bit0=1)"
echo
if [ "$CC" = "0xff" ] && [ "$CD" = "0xd8" ] && [ "$((CE & 1))" = "1" ]; then
    echo "  >>> 判读: 合并器完全正确。丢在桥 / CSI-2 组包 / D-PHY。"
elif [ "$((CE & 1))" = "1" ]; then
    echo "  >>> 判读: SOI 在码流里但不在帧首 => sel 起始相位错 (段计数与 4 不同余)。"
    echo "      下一步: 检查 merge4 的 sel 在上电/看门狗后是否真为 0。"
else
    echo "  >>> 判读: 合并器从不输出 SOI => 引擎0 的 T_HDR 没吐头。"
    echo "      下一步: 查 q_load_done / hdr_start / HDR_EN(gi==0)。"
fi

echo
echo "=== S_dbg_jpeg (0xA3~0xA6) ==="
j0=$(rg 0xA3); j1=$(rg 0xA4); j2=$(rg 0xA5); j3=$(rg 0xA6)
J=$(( (j3<<24) | (j2<<16) | (j1<<8) | j0 ))
echo "  raw=0x$(printf '%08X' $J)"
echo "  ovf=$(( J & 1 ))  enc_stall=$(( (J >> 1) & 0xFFFF ))  mrg_segc=$(( (J >> 17) & 0x3FF ))  consume=$(( (J >> 27) & 1 ))  encif_full=$(( (J >> 28) & 0xF ))"
echo "  (ovf 用来判断刚上电阶段是否溢出过; 若 CC/CD 正确则 ovf 只影响图像内容不影响头)"

echo
echo "=== MIPI 错误增量 (4s) ==="
c1=$(dmesg | grep -c MIPI_CSI2)
sleep 4
c2=$(dmesg | grep -c MIPI_CSI2)
echo "  delta=$((c2 - c1))"

echo
echo "=== buffer FFD8 复查 ==="
if [ -f /tmp/pm.py ]; then
    systemctl stop mipi-webstream
    sleep 1.5
    timeout 40 /opt/miniforge3/envs/mlk-ov/bin/python /tmp/pm.py 2>&1 \
        | grep -vE '^\[ WARN' | grep -E '===|FFD8|D8FF|zero=' | head -20
    systemctl start mipi-webstream
    sleep 1
    echo "  web=$(systemctl is-active mipi-webstream)"
else
    echo "  /tmp/pm.py 不存在, 跳过"
fi
