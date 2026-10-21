#!/bin/sh
echo "=== 等服务 active 并出帧 ==="
k=1
while [ $k -le 10 ]; do
    st=$(systemctl is-active mipi-webstream)
    if [ "$st" = "active" ]; then
        f=$(curl -s --max-time 6 http://localhost:9012/api/status \
            | tr ',' '\n' | grep '"fps"' | head -1 | grep -oE '[0-9.]+' | head -1)
        echo "  active  fps=${f:-?}"
        [ "$f" != "0.0" ] && [ -n "$f" ] && break
    else
        echo "  $st"
    fi
    sleep 10
    k=$((k + 1))
done

echo "=== 开双目演示 (dual=1 dual_demo=1) ==="
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":1,"dual_demo":1}' http://localhost:9012/api/params > /dev/null
sleep 10

echo "--- 主流程尺寸 ---"
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"width"|"height"|"fps"' | head -3

echo "--- /skel.jpg 骨架图 ---"
curl -s --max-time 6 http://localhost:9012/skel.jpg -o /tmp/sk.jpg
ls -l /tmp/sk.jpg 2>/dev/null
python3 -c "
import struct
try:
    d=open('/tmp/sk.jpg','rb').read(); i=2
    while i<len(d):
        if d[i]!=0xFF: i+=1; continue
        m=d[i+1]
        if m in (0xC0,0xC1,0xC2):
            h,w=struct.unpack('>HH', d[i+5:i+9])
            print('  骨架图 = %dx%d  %d字节'%(w,h,len(d))); break
        if m in (0xD8,0xD9): i+=2; continue
        i+=2+struct.unpack('>H', d[i+2:i+4])[0]
except Exception as e:
    print('  ', e)
"
echo "--- 骨架刷新 3 次看是否在变 ---"
i=1
while [ $i -le 3 ]; do
    curl -s --max-time 6 "http://localhost:9012/skel.jpg?t=$i" -o /tmp/sk$i.jpg
    printf '  %s  %s字节\n' "$(md5sum /tmp/sk$i.jpg | cut -d' ' -f1)" \
                            "$(stat -c %s /tmp/sk$i.jpg)"
    sleep 1
    i=$((i + 1))
done
echo "=== AI 是否开启 ==="
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -E '"active"|"note"' | head -4
