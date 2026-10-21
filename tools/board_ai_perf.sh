#!/bin/sh
echo "=== /api/status 的 ai 段 ==="
curl -s --max-time 6 http://localhost:9012/api/status | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  推流: %sx%s  fps=%s' % (d.get('width'), d.get('height'), d.get('fps')))
ai=d.get('ai') or []
if isinstance(ai, dict): ai=[ai]
for a in ai:
    print('  AI: active=%s' % a.get('active'))
    for k in ('fps','fps_target','fps_det','fps_pose','fps_submit','interval',
              'pose','src','note','queue','skip','ms','det_ms','pose_ms'):
        if k in a: print('     %-12s = %s' % (k, a[k]))
print('  参数 dual=%s dual_demo=%s ai_src=%s' % (
    d.get('params',{}).get('dual'), d.get('params',{}).get('dual_demo'),
    d.get('params',{}).get('ai_src')))
"
echo "=== CPU 占用前 6 ==="
top -b -n 1 2>/dev/null | head -12 | tail -7
echo "=== 线程数 / 各线程 CPU ==="
P=$(pgrep -f mipi_webstream | head -1)
echo "  pid=$P  线程数=$(ls /proc/$P/task | wc -l)"
top -b -n 1 -H -p $P 2>/dev/null | tail -15
