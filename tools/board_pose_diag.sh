#!/bin/sh
echo "=== /api/pose ==="
curl -s --max-time 6 http://localhost:9012/api/pose
echo
echo "=== AI 详细状态 ==="
curl -s --max-time 6 http://localhost:9012/api/status | python3 -c "
import json,sys
d=json.load(sys.stdin)
ai=d.get('ai') or {}
if isinstance(ai,list): ai=ai[0] if ai else {}
for k,v in sorted(ai.items()):
    print('  %-14s = %s' % (k, v))
print('  params.dual =', d.get('params',{}).get('dual'),
      ' dual_demo =', d.get('params',{}).get('dual_demo'),
      ' ai_src =', d.get('params',{}).get('ai_src'))
"
echo "=== 本轮是否真的有人 (看 det 相关计数) ==="
curl -s --max-time 6 http://localhost:9012/api/status | tr ',' '\n' \
  | grep -iE 'det|person|pose|num' | head -12
