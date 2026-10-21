#!/bin/sh
echo "--- demo JPEG 实际像素 ---"
python3 -c "
import struct,sys
d=open('/tmp/e.jpg','rb').read(); i=2
while i<len(d):
    if d[i]!=0xFF: i+=1; continue
    m=d[i+1]
    if m in (0xC0,0xC1,0xC2):
        h,w=struct.unpack('>HH', d[i+5:i+9]); print('  demo = %dx%d (%d 字节)'%(w,h,len(d))); break
    if m in (0xD8,0xD9): i+=2; continue
    i+=2+struct.unpack('>H', d[i+2:i+4])[0]
"
echo "--- 回单目 ---"
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":0,"dual_demo":0}' http://localhost:9012/api/params > /dev/null
sleep 4
curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/s.jpg
python3 -c "
import struct,sys
d=open('/tmp/s.jpg','rb').read(); i=2
while i<len(d):
    if d[i]!=0xFF: i+=1; continue
    m=d[i+1]
    if m in (0xC0,0xC1,0xC2):
        h,w=struct.unpack('>HH', d[i+5:i+9]); print('  单目 = %dx%d (%d 字节)'%(w,h,len(d))); break
    if m in (0xD8,0xD9): i+=2; continue
    i+=2+struct.unpack('>H', d[i+2:i+4])[0]
"
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"|"fps"' | head -4
