#!/bin/sh
# 压测硬件编码: 被杀风险规避 —— 本脚本命令行不含被测进程名
PY=/opt/miniforge3/envs/mlk-ov/bin/python
LOG=/tmp/mpp_run.log
pkill -f 'mppte''st.py' 2>/dev/null
pkill -f 'gst-launch-1.0 -q fdsrc' 2>/dev/null
sleep 1
$PY /tmp/mpptest.py /tmp/small.nv16 1728 972 ${1:-100} >$LOG 2>&1
echo "EXIT=$?"
tail -25 $LOG
