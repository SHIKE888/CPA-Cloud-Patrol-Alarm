#!/bin/sh
S=http://<SERVER_DOMAIN>
T=$(cat /root/rk/cloud/token 2>/dev/null)
H="X-Token: $T"

echo "=== /api/stats (设备列表) ==="
curl -s --max-time 8 -H "$H" "$S/api/stats" | head -c 1200
echo
echo
echo "=== /api/state (最新快照: 看 ts 是否新鲜) ==="
curl -s --max-time 8 -H "$H" "$S/api/state" | python3 -c "
import json,sys,time
try:
    d=json.load(sys.stdin)
except Exception as e:
    print('  解析失败:', e); sys.exit()
print('  ok=%s  login=%s' % (d.get('ok'), d.get('login')))
def walk(o, p=''):
    if isinstance(o, dict):
        for k,v in o.items():
            if k in ('ts','t','time','upd','updated','last_seen','age','online',
                     'node','name','fps','width','height'):
                print('  %-22s = %s' % ((p+'.'+k).lstrip('.'), v))
            if isinstance(v,(dict,list)): walk(v, p+'.'+k)
    elif isinstance(o, list):
        for i,v in enumerate(o[:4]): walk(v, '%s[%d]'%(p,i))
walk(d)
"
echo
echo "=== 连续两次 /api/state 的 ts 对比 (隔 8 秒) ==="
for k in 1 2; do
    curl -s --max-time 8 -H "$H" "$S/api/state" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  ts=%s' % (d.get('ts') or d.get('updated') or d.get('t') or '?'))
" 2>/dev/null
    [ $k -eq 1 ] && sleep 8
done
