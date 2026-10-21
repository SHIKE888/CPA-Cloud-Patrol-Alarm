#!/bin/sh
echo "=== 等 fps > 0 ==="
k=1
while [ $k -le 12 ]; do
    f=$(curl -s --max-time 6 http://localhost:9012/api/status \
        | tr ',' '\n' | grep '"fps"' | head -1 | grep -oE '[0-9.]+' | head -1)
    echo "  t=${k}0s  fps=${f:-?}"
    case "$f" in
        0.0|0|"") sleep 10; k=$((k + 1)); continue ;;
        *) break ;;
    esac
done

echo "=== 单目基线 ==="
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"|"fps"' | head -3

echo "=== 开双目演示 ==="
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":1,"dual_demo":1}' http://localhost:9012/api/params > /dev/null
sleep 10
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"|"fps"' | head -3
echo "  --- 实际帧尺寸 (取 MJPEG 流第一帧的 JPEG SOF) ---"
timeout 8 curl -s --max-time 8 http://localhost:9012/stream -o /tmp/st.bin 2>/dev/null
python3 -c "
import struct
d=open('/tmp/st.bin','rb').read(); i=d.find(b'\xff\xc0')
if i < 0: i=d.find(b'\xff\xc1')
if i < 0: i=d.find(b'\xff\xc2')
if i>=0:
    h,w=struct.unpack('>HH', d[i+5:i+9]); print('  推流帧 = %dx%d'%(w,h))
else: print('  未取到 (size=%d)'%len(d))
" 2>/dev/null || echo "  流抓取失败"

echo "=== 回单目 ==="
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":0,"dual_demo":0}' http://localhost:9012/api/params > /dev/null
sleep 6
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"|"fps"' | head -3
echo "=== CPU (双目时) ==="
top -b -n 1 2>/dev/null | grep -E 'mipi_webstream|%Cpu' | head -3
