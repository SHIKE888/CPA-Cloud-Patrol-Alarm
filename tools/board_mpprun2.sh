#!/bin/sh
# 用法: sh /tmp/mr2.sh NV12|NV16 [帧数]
FMT=${1:-NV12}
N=${2:-120}
PY=/opt/miniforge3/envs/mlk-ov/bin/python
LOG=/tmp/mpp_${FMT}.log
pkill -f 'mppte''st.py' 2>/dev/null
pkill -f 'gst-launch-1.0 -q fdsrc' 2>/dev/null
sleep 1
if [ "$FMT" = "NV12" ]; then
  $PY /tmp/mpptest.py /tmp/small.nv12 1728 972 $N NV12 >$LOG 2>&1
else
  $PY /tmp/mpptest.py /tmp/small.nv16 1728 972 $N NV16 >$LOG 2>&1
fi
echo "EXIT=$?  LOG=$LOG"
echo "--- 统计 ---"
grep -c 'premature end' $LOG
tail -6 $LOG
