#!/bin/sh
# 看 MIPI 错误的时间戳分布: 若集中在帧边界(每帧一次密集爆发), 则短包(FS/FE)是根因
dmesg -c >/dev/null 2>&1
sleep 3
echo "=== 错误时间戳(秒) 与 相邻间隔(us) ==="
dmesg | grep MIPI_CSI2 | sed -n 's/^\[ *\([0-9]*\)\.\([0-9]*\)\].*/\1 \2/p' \
  | awk '{t=$1+$2/1000000; if (n>0) {d=(t-p)*1000000; printf "%8.3f  +%7.1fus\n", t, d} else {printf "%8.3f  (start)\n", t}; p=t; n++}' \
  | head -60
echo
echo "=== 间隔直方图 (us) ==="
dmesg | grep MIPI_CSI2 | sed -n 's/^\[ *\([0-9]*\)\.\([0-9]*\)\].*/\1 \2/p' \
  | awk '{t=$1+$2/1000000; if (n>0) {d=(t-p)*1000000; if (d<10) b="<10us"; else if (d<50) b="10-50us"; else if (d<200) b="50-200us"; else if (d<1000) b="0.2-1ms"; else if (d<5000) b="1-5ms"; else b=">5ms"; c[b]++} p=t; n++} END {for (k in c) printf "  %-10s %d\n", k, c[k]}'
