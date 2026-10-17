#!/bin/sh
D=/sys/class/devfreq/27800000.gpu
echo "== $D"
ls $D
for f in load utilisation cur_freq governor available_frequencies trans_stat; do
  echo "--- $f"; cat $D/$f 2>/dev/null | head -6
done
echo "== mali debugfs"
ls /sys/kernel/debug/mali0 2>/dev/null
for f in gpu_usage utilisation dvfs_period; do
  echo "--- $f"; cat /sys/kernel/debug/mali0/$f 2>/dev/null | head -3
done
echo "== misc mali0"
ls /sys/class/misc/mali0/device/ 2>/dev/null
echo "== rga"
ls /sys/class/devfreq/ 2>/dev/null
for d in /sys/class/devfreq/*; do echo "$d load=$(cat $d/load 2>/dev/null)"; done
echo "== top gpu-ish load (1s)"
cat /sys/kernel/debug/rknpu/load 2>/dev/null
