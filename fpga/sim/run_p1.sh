#!/bin/bash
#=============================================================================
# run_p1.sh —— 编译并运行 P1 阶段仿真 (iverilog)
#
#   ./run_p1.sh            # 跑测试
#   ./run_p1.sh -dump      # 同时输出 tb_p1.vcd 波形
#
# 依赖: iverilog + vvp   (Debian: apt-get install -y iverilog)
#=============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
JPEG="$HERE/../uisrc/01_rtl/jpeg"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "!! 找不到 iverilog。装一下: apt-get install -y iverilog" >&2
    exit 1
fi

cd "$HERE" || exit 1

# 表文件改动过就重新生成一次, 保证仿真用的表就是 RTL 用的表
if [ -f "$HERE/../../tools/gen_jpeg_tables.py" ]; then
    ( cd "$HERE/../.." && python3 tools/gen_jpeg_tables.py >/dev/null 2>&1 ) \
        && echo "[表] jpeg_defs.vh 已刷新"
fi

echo "[编译] tb_p1.v + jpeg_*.v"
iverilog -g2005 \
    -I "$JPEG" \
    -o tb_p1.vvp \
    "$HERE/tb_p1.v" \
    "$JPEG/jpeg_cmd_1wire.v" \
    "$JPEG/jpeg_regfile.v" \
    "$JPEG/jpeg_qtable_ram.v" \
    2>&1 | sed 's/^/  /'

if [ ! -f tb_p1.vvp ]; then
    echo "!! 编译失败" >&2
    exit 1
fi

echo "[仿真] 开始"
vvp tb_p1.vvp $@
rc=$?

if [ -f tb_p1.vcd ]; then
    echo "[波形] tb_p1.vcd ($(stat -c%s tb_p1.vcd) 字节)"
fi
exit $rc
