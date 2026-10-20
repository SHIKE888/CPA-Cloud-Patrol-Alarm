#!/bin/sh
# 在板上跑: 打印 /api/status 关键字段 + 双目状态
J=/tmp/dual_st.json
curl -s --max-time 5 localhost:9012/api/status > $J || { echo "curl 失败"; exit 1; }
python3 - "$J" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("backend", "device", "width", "height", "fps", "frame_id", "clients"):
    print("%-11s %s" % (k, d.get(k)))
print("-" * 52)
dd = d.get("dual")
if dd is None:
    print("dual        服务端没有这个字段 (还是旧版本?)")
else:
    print("enabled     %s" % dd.get("enabled"))
    print("active      %s" % dd.get("active"))
    print("last_src    %s" % dd.get("last_src"))
    print("cam0_age_ms %s" % dd.get("cam0_age_ms"))
    print("cam1_age_ms %s" % dd.get("cam1_age_ms"))
    print("stat        %s" % json.dumps(dd.get("stat"), ensure_ascii=False))
print("-" * 52)
p = d.get("ai") or {}
print("ai.active   %s" % p.get("active"))
print("ai.fps      %s" % p.get("ai_fps"))
PY
