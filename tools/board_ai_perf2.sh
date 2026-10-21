#!/bin/sh
echo "=== 等 active 且出帧 ==="
k=1
while [ $k -le 10 ]; do
    f=$(curl -s --max-time 6 http://localhost:9012/api/status 2>/dev/null \
        | tr ',' '\n' | grep '"fps"' | head -1 | grep -oE '[0-9.]+' | head -1)
    [ -n "$f" ] && [ "$f" != "0.0" ] && { echo "  推流 fps=$f"; break; }
    sleep 10; k=$((k + 1))
done

echo "=== 确保双目+AI ==="
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":1,"dual_demo":0,"ai_src":0}' http://localhost:9012/api/params > /dev/null
sleep 8

echo "=== AI 性能 (连续采 3 次看是否稳定) ==="
i=1
while [ $i -le 3 ]; do
    curl -s --max-time 6 http://localhost:9012/api/status | python3 -c "
import json,sys
d=json.load(sys.stdin)
ai=d.get('ai') or {}
if isinstance(ai,list): ai=ai[0] if ai else {}
print('  推流 %sx%s @%s | ai fps=%s det_ms=%s pose_ms=%s pose=%s' % (
    d.get('width'), d.get('height'), d.get('fps'),
    ai.get('fps'), ai.get('det_ms'), ai.get('pose_ms'), ai.get('fps_pose')))
"
    sleep 3
    i=$((i + 1))
done

echo "=== 骨架图 ==="
curl -s --max-time 6 http://localhost:9012/skel.jpg -o /tmp/sk.jpg
python3 -c "
import struct
d=open('/tmp/sk.jpg','rb').read(); i=2
while i<len(d):
    if d[i]!=0xFF: i+=1; continue
    m=d[i+1]
    if m in (0xC0,0xC1,0xC2):
        h,w=struct.unpack('>HH', d[i+5:i+9])
        print('  %dx%d  %d字节'%(w,h,len(d))); break
    if m in (0xD8,0xD9): i+=2; continue
    i+=2+struct.unpack('>H', d[i+2:i+4])[0]
" 2>/dev/null
echo "=== 总 CPU ==="
top -b -n 1 2>/dev/null | grep -E '%Cpu|mipi_webstream' | head -2
