#!/bin/sh
# 开机后把 state_snapshot.json 里的相机物理量写回 FPGA/传感器。
# 由 cam-restore.service (oneshot, After=mipi-webstream.service) 调用，
# 也可以手工执行：sh /root/rk/deploy/restore_cam.sh
#
# 说明：只回写 cam（曝光/增益/EV/白平衡/有效画面）。
#      网页参数/AI/云台由服务端 ParamStore 读 state.json 自动恢复，这里不重复写，
#      避免两处来源打架。
set -u
SNAP=/root/rk/deploy/state_snapshot.json
PY=/opt/miniforge3/envs/mlk-ov/bin/python
PORT=9012

[ -f "$SNAP" ] || { echo "没有快照 $SNAP，跳过（先执行 save_state.sh）"; exit 0; }

# 等 API 就绪：开机时 mipi-webstream 要 10~20s 才监听（FPGA 复位 + sensor 锁相 + AI 加载）
i=0
while [ $i -lt 120 ]; do
    if curl -sf -m 2 "http://127.0.0.1:$PORT/api/fpga" -o /dev/null 2>/dev/null; then
        break
    fi
    i=$((i + 1))
    sleep 1
done
if [ $i -ge 120 ]; then
    echo "等了 120s /api/fpga 仍不可用，放弃回写"
    exit 1
fi
echo "API 就绪（等待 ${i}s），开始回写相机参数"

BODY=$($PY -c "import json;d=json.load(open('$SNAP'));print(json.dumps(d.get('cam') or {}))")
if [ "$BODY" = "{}" ]; then
    echo "快照里没有 cam 字段，跳过"
    exit 0
fi
echo "POST /api/fpga $BODY"

curl -sf -m 10 -X POST -H "Content-Type: application/json" -d "$BODY" \
     "http://127.0.0.1:$PORT/api/fpga" -o /tmp/_restore_resp.json
RC=$?
if [ $RC -ne 0 ]; then
    echo "回写失败 (curl rc=$RC)"
    exit 1
fi

$PY - /tmp/_restore_resp.json <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("响应解析失败:", e); raise SystemExit(1)
ph = d.get("phys") or {}
print("回读 phys:", json.dumps(ph, ensure_ascii=False))
print("write_ok :", d.get("write_ok"), d.get("message") or "")
PY
