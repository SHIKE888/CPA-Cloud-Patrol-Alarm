#!/bin/sh
echo "=== 等出帧 ==="
k=1
while [ $k -le 10 ]; do
    f=$(curl -s --max-time 6 http://localhost:9012/api/status 2>/dev/null \
        | tr ',' '\n' | grep '"fps"' | head -1 | grep -oE '[0-9.]+' | head -1)
    [ -n "$f" ] && [ "$f" != "0.0" ] && { echo "  fps=$f"; break; }
    sleep 10; k=$((k + 1))
done

echo "=== 切双目 ==="
curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":1,"dual_demo":0,"ai_src":0}' http://localhost:9012/api/params > /dev/null
sleep 8

echo "=== /api/pose 原始返回 ==="
curl -s --max-time 6 http://localhost:9012/api/pose | head -c 600
echo
echo "=== 解析 ==="
curl -s --max-time 6 http://localhost:9012/api/pose | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  ok=%s  坐标系=%sx%s  persons=%d' % (
    d.get('ok'), d.get('w'), d.get('h'), len(d.get('persons') or [])))
for p in (d.get('persons') or [])[:3]:
    k=p.get('k') or []
    live=[i for i,q in enumerate(k) if q[2]>=0.3]
    print('    id=%s score=%s box=%s  有效关节点=%d/%d %s' % (
        p.get('t'), p.get('s'), p.get('b'), len(live), len(k), live))
"
echo "=== AI fps (确认没被拖慢) ==="
curl -s --max-time 6 http://localhost:9012/api/status | python3 -c "
import json,sys
d=json.load(sys.stdin); ai=d.get('ai') or {}
if isinstance(ai,list): ai=ai[0] if ai else {}
print('  推流 %sx%s @%s | ai fps=%s det_ms=%s' % (
    d.get('width'), d.get('height'), d.get('fps'), ai.get('fps'), ai.get('det_ms')))
"
echo "=== CPU ==="
top -b -n 1 2>/dev/null | grep -E '%Cpu' | head -1
