#!/bin/sh
echo "== devfreq"
for d in /sys/class/devfreq/*; do
  echo "$d cur=$(cat $d/cur_freq 2>/dev/null) load=$(cat $d/load 2>/dev/null) util=$(cat $d/utilisation 2>/dev/null)"
done
echo "== rknpu"
cat /sys/kernel/debug/rknpu/load 2>/dev/null
ls /sys/kernel/debug/rknpu 2>/dev/null
echo "== thermal"
for t in /sys/class/thermal/thermal_zone*; do echo "$t $(cat $t/type 2>/dev/null) $(cat $t/temp 2>/dev/null)"; done | head -8
echo "== meminfo"
head -3 /proc/meminfo
echo "== gpu class"
ls /sys/class/devfreq 2>/dev/null
echo "== mali"
ls /sys/class/misc/mali0/device 2>/dev/null | head
