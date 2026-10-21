#!/bin/sh
echo "=== 开双目演示 (dual=1 dual_demo=1) ==="
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":1,"dual_demo":1}' http://localhost:9012/api/params > /dev/null
sleep 6
echo "--- 状态里的实际输出尺寸 ---"
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"|"fps"|"dual"|"tag"' | head -10
echo "--- 快照实际像素 ---"
curl -s --max-time 8 http://localhost:9012/snapshot.jpg -o /tmp/d.jpg
python3 -c "
import struct,sys
d=open('/tmp/d.jpg','rb').read()
i=2
while i<len(d):
    if d[i]!=0xFF: i+=1; continue
    m=d[i+1]
    if m in (0xC0,0xC1,0xC2):
        h,w=struct.unpack('>HH', d[i+5:i+9]); print('  JPEG = %dx%d  %d字节'%(w,h,len(d))); sys.exit()
    if m in (0xD8,0xD9): i+=2; continue
    i+=2+struct.unpack('>H', d[i+2:i+4])[0]
print('  解析失败 %d字节'%len(d))
"
echo "=== 关掉演示, 回单目 ==="
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":0,"dual_demo":0}' http://localhost:9012/api/params > /dev/null
sleep 4
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"' | head -4
