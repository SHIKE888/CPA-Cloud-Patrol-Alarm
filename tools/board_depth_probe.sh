#!/bin/bash
# board_depth_probe.sh —— 在 RK3576 板上验收双目深度点云
#
#   用法: bash board_depth_probe.sh [样本数]
#
# 做三件事:
#   1) 把推流切到双目(dual=1), 等两路都稳定;
#   2) 连续拉 N 次 /api/depth, 存到 /tmp/depth_*.json(含点云本体);
#   3) 打印点数/量程/耗时/帧率, 以及 /api/status 里的深度引擎状态。
#
# 最后把 /tmp/depth_*.json scp 回来用 tools/depth_decode.py 解码即可看
# 真实坐标(不必开网页)。
B=${DEPTH_API:-http://127.0.0.1:9012}
N=${1:-3}

echo "== 切双目 =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' \
     -d '{"dual":1}' "$B/api/params" >/dev/null
sleep 4

echo "== 采样 $N 次 /api/depth =="
rm -f /tmp/depth_*.json
i=1
while [ "$i" -le "$N" ]; do
    curl -s -m 8 "$B/api/depth" -o "/tmp/depth_$i.json"
    i=$((i + 1))
    sleep 1
done

echo "== 摘要 =="
python3 - <<'PY'
import base64, glob, json, struct
for path in sorted(glob.glob("/tmp/depth_*.json")):
    try:
        d = json.load(open(path))
    except Exception as e:
        print(path, "读取失败", e)
        continue
    if not d.get("ok"):
        print(path, "ok=False", d.get("reason"), d.get("err"))
        continue
    raw = base64.b64decode(d["pts"])
    n = d["n"]
    xs = []; ys = []; zs = []
    for k in range(n):
        x, y, z = struct.unpack_from("<hhh", raw, k * 9)
        xs.append(x); ys.append(y); zs.append(z)
    xs.sort(); ys.sort(); zs.sort()
    q = lambda a, p: a[min(len(a) - 1, int(len(a) * p))]
    print("%s) n=%d valid=%.1f%% ms=%.1f fps=%.1f age=%s stale=%s"
          % (path, n, d["valid"] * 100, d.get("ms", 0), d.get("fps", 0),
             d.get("age"), d.get("stale")))
    print("   z %d..%d mm (中位 %d)   x %d..%d mm   y %d..%d mm"
          % (q(zs, 0.02), q(zs, 0.98), q(zs, 0.5),
             q(xs, 0.02), q(xs, 0.98), q(ys, 0.02), q(ys, 0.98)))
    print("   focal=%spx fov=%s° 处理尺寸 %sx%s 算法 %s"
          % (d.get("focal_px"), d.get("fov_deg"), d.get("pw"), d.get("ph"),
             d.get("alg")))
PY
