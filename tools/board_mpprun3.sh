#!/bin/sh
# 用法: sh /tmp/mr3.sh NV12|NV16 [帧数]
FMT=${1:-NV12}
N=${2:-80}
PY=/opt/miniforge3/envs/mlk-ov/bin/python
LOG=/tmp/mp2_${FMT}.log
pkill -f 'mppte''st' 2>/dev/null
pkill -f 'gst-launch-1.0 -q fdsrc' 2>/dev/null
sleep 1
if [ "$FMT" = "NV12" ]; then F=/tmp/small.nv12; else F=/tmp/small.nv16; fi
timeout 120 $PY -u /tmp/mpptest2.py $F 1728 972 $N $FMT >$LOG 2>&1
echo "EXIT=$?"
grep -c 'premature end' $LOG
tail -8 $LOG
