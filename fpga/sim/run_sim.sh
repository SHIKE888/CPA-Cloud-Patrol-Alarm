#!/bin/bash
#=============================================================================
# run_sim.sh —— 统一的仿真入口 (iverilog)
#
#   ./run_sim.sh p1            # 寄存器堆 + 量化表 + 单线命令通道
#   ./run_sim.sh tsrc          # CSI-2 传输自测源 (逐字节可校验载荷)
#   ./run_sim.sh tsrc -dump    # 额外输出 vcd 波形
#
# 依赖: apt-get install -y iverilog
#=============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
JPEG="$HERE/../uisrc/01_rtl/jpeg"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "!! 找不到 iverilog。装一下: apt-get install -y iverilog" >&2
    exit 1
fi

TBNAME="${1:-p1}"
DUMPARG=""
if [ "${2:-}" = "-dump" ]; then
    DUMPARG="-dump"
fi

case "$TBNAME" in
    p1)
        TOP="tb_p1"
        SRCS="$HERE/tb_p1.v $JPEG/jpeg_cmd_1wire.v $JPEG/jpeg_regfile.v $JPEG/jpeg_qtable_ram.v"
        DESC="P1: 寄存器堆 + 量化表 + 单线命令通道"
        ;;
    tsrc)
        TOP="tb_test_src"
        SRCS="$HERE/tb_test_src.v $JPEG/csi2_test_src.v"
        DESC="CSI-2 传输自测源"
        ;;
    *)
        echo "用法: $0 [p1|tsrc] [-dump]" >&2
        exit 2
        ;;
esac

cd "$HERE" || exit 1

# jpeg_defs.vh 是根据生成器产出的, 顺手确认它是最新的
GEN="$HERE/../../tools/gen_jpeg_tables.py"
if [ -f "$GEN" ] && command -v python3 >/dev/null 2>&1; then
    ( cd "$HERE/../.." && python3 tools/gen_jpeg_tables.py >/dev/null 2>&1 ) \
        && echo "[表] jpeg_defs.vh 已刷新"
fi

echo "[仿真] $DESC"
iverilog -g2005 -I "$JPEG" -o "$TOP.vvp" $SRCS 2>&1 | sed 's/^/  /'
if [ ! -f "$TOP.vvp" ]; then
    echo "!! 编译失败" >&2
    exit 1
fi

vvp "$TOP.vvp" $DUMPARG
rc=$?
[ -f "$TOP.vcd" ] && echo "[波形] $TOP.vcd ($(stat -c%s "$TOP.vcd") 字节)"
exit $rc
