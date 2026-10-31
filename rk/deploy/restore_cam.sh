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
else
    echo "POST /api/fpga $BODY"
    curl -sf -m 10 -X POST -H "Content-Type: application/json" -d "$BODY" \
         "http://127.0.0.1:$PORT/api/fpga" -o /tmp/_restore_resp.json
    RC=$?
    if [ $RC -ne 0 ]; then
        echo "相机参数回写失败 (curl rc=$RC)"
    else
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
    fi
fi

# ---- 推流模式（dual）----
# 服务端启动时并不会自动把 state.json 里的 dual 真正应用上去（上电实测：参数是 1
# 但实际输出 1920x1080 单目），而网页一打开又会按"服务端当前模式"把 dual 推回去，
# 结果每次重启都掉回单目。这里在开机时显式 POST 一次。
DUAL=$($PY -c "import json;d=json.load(open('$SNAP'));p=d.get('params') or {};print(p.get('dual',''))")
if [ -n "$DUAL" ]; then
    echo "POST /api/params dual=$DUAL"
    curl -sf -m 10 -X POST -H "Content-Type: application/json" -d "{\"dual\": $DUAL}" \
         "http://127.0.0.1:$PORT/api/params" > /dev/null
    sleep 3
    curl -sf -m 6 "http://127.0.0.1:$PORT/api/status" -o /tmp/_restore_st.json || true
    $PY - /tmp/_restore_st.json <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
print("推流: %sx%s  fps=%s  dual=%s"
      % (d.get("width"), d.get("height"), d.get("fps"),
         (d.get("params") or {}).get("dual")))
PY
fi
