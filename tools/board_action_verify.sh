#!/bin/sh
echo "=== 板上文件版本 ==="
wc -l /root/rk/ai/board/action_rules.py
md5sum /root/rk/ai/board/action_rules.py
grep -c 'ok_l and ok_r' /root/rk/ai/board/action_rules.py | sed 's/^/  ok_l and ok_r 出现次数: /'
grep -n 'arm_ext > 0.5' /root/rk/ai/board/action_rules.py | sed 's/^/  /'
grep -n "t, 0.3, score=min(1.0, sw_max" /root/rk/ai/board/action_rules.py | sed 's/^/  /'

echo "=== 服务 ==="
systemctl is-active mipi-webstream
for k in 1 2 3 4 5 6; do
    f=$(curl -s --max-time 6 http://localhost:9012/api/status 2>/dev/null \
        | tr ',' '\n' | grep '"fps"' | head -1 | grep -oE '[0-9.]+' | head -1)
    [ -n "$f" ] && [ "$f" != "0.0" ] && { echo "  出帧 fps=$f"; break; }
    sleep 10
done

echo "=== AI 状态 (确认没报错) ==="
curl -s --max-time 6 http://localhost:9012/api/status | python3 -c "
import json,sys
d=json.load(sys.stdin); ai=d.get('ai') or {}
if isinstance(ai,list): ai=ai[0] if ai else {}
print('  fps=%s det_ms=%s err=%r last_error=%r' % (
    ai.get('fps'), ai.get('det_ms'), ai.get('err'), ai.get('last_error')))
for x in (ai.get('detections') or [])[:3]:
    print('   tid=%s score=%s labels=%s labels_en=%s n_kpt=%s' % (
        x.get('tid'), x.get('score'), x.get('labels'), x.get('labels_en'), x.get('n_kpt')))
"
