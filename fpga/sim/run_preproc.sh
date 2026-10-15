#!/bin/sh
# run_preproc.sh —— 在开发板上跑预处理流水线仿真
#   用法: sh run_preproc.sh [目录]
set -e
D=${1:-/root/rk/preproc_sim}
cd "$D"

echo "== 编译 =="
iverilog -g2005 -o tb_preproc.vvp \
    tb_preproc.v \
    preproc_top.v preproc_win3x3.v preproc_edge.v
echo "   OK"

echo "== 运行 =="
vvp tb_preproc.vvp > preproc_log.txt 2>&1

A=$(grep -c '^A ' preproc_log.txt || true)
B=$(grep -c '^B ' preproc_log.txt || true)
echo "   日志 $D/preproc_log.txt  ($(wc -l < preproc_log.txt) 行)"
echo "   Phase A 样本 $A 组"
echo "   Phase B 样本 $B 拍"

if ! grep -q '^DONE' preproc_log.txt; then
    echo "!! 仿真未正常结束, 末尾日志:"
    tail -20 preproc_log.txt
    exit 1
fi
echo "   完成"
