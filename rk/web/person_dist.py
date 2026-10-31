# -*- coding: utf-8 -*-
"""人员测距 / 方位匹配：把 AI 检测框和双目深度热力图对上。

为什么单独一层
--------------
AI（`/api/ai`）和深度（`/api/depth`）是两条独立管线：
  * AI 喂的是**左半幅缩到 960x540** 的画面，box/aim 是那张图上的像素坐标；
  * 深度在 512x288 上做 SGBM，热力图再降一半（256x144），
    值是 8bit 的**对数**量化（0=无效，1..255 对应 zlo..zhi）。
两条链路的更新节奏也不同（AI ~30fps 推理、深度 10Hz）。这里只做三件事：

  1) 把 AI 给的**肩部中点**（没跑姿态关键点时才退回瞄准点 / 框中心）换算到
     热力图坐标，取一个小窗口的**有效深度中位数**当这个人到相机的距离；
  2) 用同一窗口的 u 偏移 + 焦距算水平方位角 `atan((u-cx)/f)`；
  3) 结合云台 yaw/pitch，把 (距离, 方位) 变成**相机→车体**的向量
     （车体系：x 前 / y 左 / z 上），前端再按小车位姿转到地图系。

约束
----
* 只做几何换算，不猜：任何一环不可用（无深度 / 未标定 / 热力图无效 / 距离越界）
  都返回 `ok=False` + `reason`，前端据此**不画**这个人，而不是画个假位置。
* 深度图与视频同向（stereo_depth 已修掉水平镜像 bug），所以 u 方向不需要翻转。
* 双目模式下 AI 喂的就是左半幅（`ai_src`=cam1=左），和深度引擎的参考图同一路。

对外只有 `match_targets()`。
"""

import base64
import math
import threading
import time

try:
    import numpy as np
except Exception as _e:                                      # noqa: BLE001
    np = None
    NP_ERR = "%s: %s" % (type(_e).__name__, _e)
else:
    NP_ERR = ""

# ---- 匹配窗口 ----
# 瞄准点窗口半径（占热力图宽度的比例）。0.03 => 256 宽的热力图里半径 ≈ 8 px，
# 换算到 1920 全宽约 ±115 px，大致相当于"胸口那一块"：框再大多也不会吃到背景。
AIM_R = 0.030
MIN_AIM_VALID = 5          # 瞄准点窗口里至少这么多有效像素才算数
# 兜底：瞄准点没效就退回"框内躯干带"（x 30%~70%、y 30%~65%），取 p25 当前表面
MIN_BOX_VALID = 12
SPREAD_WARN = 1.8          # p75/p25 超过它 -> 窗口里混了背景，conf 打折
Z_SANE = (0.20, 15.0)      # 合理的距离区间（超出就不报位置）
# 深度结果超过这么久就当过期。原来 2.5s 太宽松：云台在摆动时，2.5 秒前的
# 画面和"此刻"的云台角完全对不上，算出来的位置能差一米以上（用户报的
# "大幅跳变"）。0.8s 是 SGBM 一轮(约 0.1s)+ 排队波动的合理上界。
MAX_AGE = 0.8

# ---- 输出平滑（同一目标跨帧）----
#  为什么要有：即使角度和图像都对齐了，采样点（肩中点/瞄准点）本身也在
#  帧间抖动（关键点检测、SGBM 空洞），直接输出会让地图上的点在原地"炸开"。
#  这里对 (x,y,up) 做指数平滑：跟手程度由 SMOOTH_TAU 决定（0.3s ≈ 3~4 帧）。
SMOOTH_TAU = 0.30
SMOOTH_RESET_M = 2.5       # 单帧跳这么远 = 目标切换/测距跑飞 -> 直接重置
_SMOOTH_TTL = 8.0
_SMOOTH = {}               # tid -> {"x","y","up","t"}
_SMOOTH_LOCK = threading.Lock()


def _smooth_rel(tid, rel, now):
    """同一目标的 3D 相对位置做指数平滑。tid 为空 / rel 为空就原样返回。"""
    if tid is None or not rel:
        return rel
    with _SMOOTH_LOCK:
        for k in [k for k, v in _SMOOTH.items() if now - v["t"] > _SMOOTH_TTL]:
            _SMOOTH.pop(k, None)
        s = _SMOOTH.get(tid)
        if s is None:
            _SMOOTH[tid] = {"x": rel["x"], "y": rel["y"],
                            "up": rel["up"], "t": now}
            return dict(rel)
        dt = min(2.0, max(0.02, now - s["t"]))
        d = math.hypot(rel["x"] - s["x"], rel["y"] - s["y"])
        if d > SMOOTH_RESET_M:
            s.update(x=rel["x"], y=rel["y"], up=rel["up"], t=now)
            return dict(rel)
        a = 1.0 - math.exp(-dt / SMOOTH_TAU)
        s["x"] += a * (rel["x"] - s["x"])
        s["y"] += a * (rel["y"] - s["y"])
        s["up"] += a * (rel["up"] - s["up"])
        s["t"] = now
        ground = math.hypot(s["x"], s["y"])
        return {"x": s["x"], "y": s["y"], "up": s["up"], "ground": ground,
                "range": math.hypot(ground, s["up"])}

# heat 解码缓存：同一帧只解一次 base64（10Hz 轮询下这点开销可不忽略）
_CACHE = {"key": None, "q": None}
_CACHE_LOCK = threading.Lock()


# --------------------------------------------------------------------- 解码
def _heat_q(depth):
    """depth['heat']（base64 的 8bit 对数量化图）→ numpy uint8（h,w），按 t_done 缓存。"""
    if np is None or not isinstance(depth, dict) or not depth.get("heat"):
        return None
    key = depth.get("t_done")
    with _CACHE_LOCK:
        if key is not None and _CACHE["key"] == key and _CACHE["q"] is not None:
            return _CACHE["q"]
    try:
        raw = base64.b64decode(depth["heat"])
        w = int(depth.get("hw") or 0)
        h = int(depth.get("hh") or 0)
        if w <= 0 or h <= 0 or len(raw) < w * h:
            return None
        q = np.frombuffer(raw[:w * h], np.uint8).reshape(h, w)
    except Exception:                                        # noqa: BLE001
        return None
    with _CACHE_LOCK:
        _CACHE["key"] = key
        _CACHE["q"] = q
    return q


def _q_to_z(q, zlo, zhi):
    """量化值 → 距离（米）。与 stereo_depth 里的对数量化严格互逆。"""
    llo = math.log(max(float(zlo), 1e-3))
    lhi = math.log(max(float(zhi), float(zlo) * 1.0001))
    v = (q.astype(np.float32) - 1.0) / 254.0
    return np.exp(llo + v * (lhi - llo))


# --------------------------------------------------------------------- 取样
def _window_stats(q, x0, y0, x1, y1, zlo, zhi, min_n):
    """在一个像素窗口里取有效深度的中位数 / 分位。返回 dict 或 None。"""
    h, w = q.shape
    x0 = max(0, int(x0))
    y0 = max(0, int(y0))
    x1 = min(w, int(x1))
    y1 = min(h, int(y1))
    if x1 - x0 < 2 or y1 - y0 < 2:
        return None
    sub = q[y0:y1, x0:x1]
    ok = sub > 0                                  # 0 = 该像素没匹配上
    n = int(ok.sum())
    if n < min_n:
        return None
    zs = _q_to_z(sub[ok], zlo, zhi)
    med = float(np.median(zs))
    lo, hi = np.percentile(zs, [25.0, 75.0])
    lo = float(lo)
    hi = float(hi)
    return {"z": med, "zlo": lo, "zhi": hi, "n": n,
            "spread": (hi / max(lo, 1e-6)) if lo > 0 else 9.9,
            "box": [x0, y0, x1, y1]}


def _apply_h(H, u, v):
    """单应 H（3x3，行优先 9 个数）作用到像素点上；H 为空就原样返回。"""
    if not H or len(H) < 9:
        return float(u), float(v)
    x = H[0] * u + H[1] * v + H[2]
    y = H[3] * u + H[4] * v + H[5]
    w = H[6] * u + H[7] * v + H[8]
    if abs(w) < 1e-9:
        return float(u), float(v)
    return x / w, y / w


def _probe_video_pt(q, depth, u_v, v_v, box_w_v, zlo, zhi, src="aim"):
    """在**视频坐标**给的点上取深度。

    视频坐标 ≠ 热力图坐标：标定后的极线校正会把左图横向压缩并旋转（本工程
    的 R 里带着十几度的偏航误差），所以必须经 `img2rect` 单应先换到校正坐标，
    再按比例落到热力图上。未标定时 img2rect 为空，两者就是同一套坐标。
    """
    hh, hw = q.shape
    w_full = float(depth.get("w") or 1.0)
    h_full = float(depth.get("h") or 1.0)
    ur, vr = _apply_h(depth.get("img2rect"), u_v, v_v)
    hu = ur / w_full * hw
    hv = vr / h_full * hh
    # ⚠ 采样点必须落在热力图**里面**。热力图是极线校正后的左图，覆盖的画面
    #   范围比原始图略小（本工程实测：原始 u∈[59,1720]、v∈[0,1080] 之外
    #   映射出去就出界），人走到画面最左/最右时 hu 会跑到图外；那时窗口只能
    #   被边界裁掉一半，采到的是边缘背景，距离直接错。
    #   宁可报"不在深度视野"也不给个错的位置（用户反馈的"对不上"）。
    if not (0 <= hu < hw and 0 <= hv < hh):
        return {"src": "outside", "hu": hu, "hv": hv, "n": 0}
    r = max(2, int(round(AIM_R * hw)))
    st = _window_stats(q, hu - r, hv - r, hu + r + 1, hv + r + 1,
                       zlo, zhi, MIN_AIM_VALID)
    if st is not None:
        st["src"] = src
        st["hu"], st["hv"] = hu, hv
        return st
    # 兜底：用框宽当窗口（人身上总有一点有效深度）
    rb = max(r, int(round(0.20 * max(1.0, box_w_v) / w_full * hw)))
    st = _window_stats(q, hu - rb, hv - rb, hu + rb + 1, hv + rb + 1,
                       zlo, zhi, MIN_BOX_VALID)
    if st is not None:
        st["src"] = "box"
        st["hu"], st["hv"] = hu, hv
    return st


def _pick_sample_pt(d, aw, ah):
    """挑深度采样点（AI 帧像素坐标）。返回 (u, v, src, pair)。

    优先级（2026-11-01 用户要求：深度采样**优先取肩部中心**）：
      1. `sh`  两肩中点 —— 肩/颈根那一块正对相机、面积大、不会被手臂和背包
                挡住，是整幅人体上深度最稳的地方；而且不随"框被裁"滑动
                （框中心会：人走近或走到画面边缘时框被切，中心滑到大腿）；
      2. `aim` ai_overlay 的瞄准点（能全包 = 头脚中点，装不下 = 头部）；
      3. 框中心 —— 连瞄准点都没有（没跑姿态模型）时才用。
    """
    # 1) 肩部中点
    sh = d.get("sh")
    try:
        if sh and len(sh) >= 2 and (aw <= 0 or (0 <= float(sh[0]) < aw)):
            return (float(sh[0]), float(sh[1]), "shoulder",
                    bool(d.get("sh_pair", True)))
    except (TypeError, ValueError):
        pass
    # 2) 瞄准点
    aim = d.get("aim")
    try:
        if aim and len(aim) >= 2:
            return float(aim[0]), float(aim[1]), "aim", False
    except (TypeError, ValueError):
        pass
    # 3) 框中心
    box = d.get("box") or [0, 0, 0, 0]
    try:
        bx0, by0, bx1, by1 = [float(v) for v in box[:4]]
    except (TypeError, ValueError):
        bx0 = by0 = bx1 = by1 = 0.0
    if (bx1 - bx0) > 2 and (by1 - by0) > 2:
        return (bx0 + bx1) / 2.0, (by0 + by1) / 2.0, "box", False
    return aw * 0.5, ah * 0.5, "frame", False



# --------------------------------------------------------------- 坐标变换
def to_base(dist, u, v, f_px, cx, cy, yaw_deg=0.0, pitch_deg=0.0):
    """相机坐标 (u,v,dist) → 车体系向量 (x 前 / y 左 / z 上)。

    约定（和页面上云台/雷达一致）：
      * yaw 正值 = 视线**向左**（+Yaw = 左，与 gimbal_keyctrl 键位一致）
      * pitch 正值 = 视线**向下**（云台低头）
      * 云台零点 ≈ 车头方向（偏置由页面参数 `gimbal_off` 补）
    相机系 (Xc 右, Yc 下, Zc 前)；零偏航零俯仰时 Xb=Zc, Yb=-Xc, Zb=-Yc。
    """
    if f_px <= 0:
        return None
    Xc = (float(u) - float(cx)) * dist / float(f_px)
    Yc = (float(v) - float(cy)) * dist / float(f_px)
    Zc = float(dist)
    n = math.sqrt(Xc * Xc + Yc * Yc + Zc * Zc)
    if n <= 0:
        return None
    xc, yc, zc = Xc / n, Yc / n, Zc / n
    # 相机 -> 车体（零俯仰）
    vx, vy, vz = zc, -xc, -yc
    # 俯仰：绕 +y(左) 轴转 θ，forward (1,0,0) -> (cosθ, 0, -sinθ)
    th = math.radians(float(pitch_deg or 0.0))
    ct, st = math.cos(th), math.sin(th)
    vx, vz = vx * ct + vz * st, -vx * st + vz * ct
    # 偏航：绕 +z(上) 轴转 φ，(1,0,0) -> (cosφ, sinφ, 0)
    ph = math.radians(float(yaw_deg or 0.0))
    cp, sp = math.cos(ph), math.sin(ph)
    bx, by = vx * cp - vy * sp, vx * sp + vy * cp
    return {
        "x": bx * n,                                        # 车体前向(m)
        "y": by * n,                                        # 车体左向(m)
        "ground": math.hypot(bx, by) * n,                   # 水平距离(m)
        "range": n,                                         # 斜距(m)
        "up": vz * n,                                       # 高度差(相机为原点, 向上为正)
    }


# --------------------------------------------------------------- 对外入口
def match_targets(dets, depth, ai_wh, yaw_deg=0.0, pitch_deg=0.0,
                  locked_tid=None, ai_on_left=True, smooth=True):
    """给每个 AI 检测算距离/方位。

    参数
    ----
    dets      : ai_overlay.status()['detections']
    depth     : StereoDepth.snapshot() 的结果（含 heat/hw/hh/zlo/zhi/focal_px）
    ai_wh     : 喂给 AI 那一帧的 [w, h]（= ai.status()['frame']）
    yaw_deg   : 云台相对零点的 yaw（+ 向左）
    pitch_deg : 云台相对零点的 pitch（+ 向下）
    locked_tid: 追踪锁定的 tid（用于给前端标名，这里只透传）
    ai_on_left: AI 喂的是不是**左目**（双目下由 params.ai_src 决定）。
                False 时按视差把右目的 u 换算到左目再做方位估计。

    返回 list[dict]，每项至少含 tid / ok / reason。
    """
    out = []
    dets = dets or []

    # ---- 深度这一侧可用吗 ----
    dep_ok = (np is not None) and isinstance(depth, dict) and bool(depth.get("ok"))
    q = _heat_q(depth) if dep_ok else None
    if dep_ok and q is not None:
        zlo = float(depth.get("zlo") or 0.0)
        zhi = float(depth.get("zhi") or 0.0)
        if zlo <= 0 or zhi <= zlo:
            q = None

    reason = ""
    if np is None:
        reason = "numpy 不可用(%s)" % NP_ERR
    elif not dep_ok:
        reason = (str(depth.get("reason") or "深度不可用")
                  if isinstance(depth, dict) else "深度不可用")
    elif q is None:
        reason = "热力图不可用"
    else:
        # 深度结果太旧就不能拿来定位：人一走动就是几十厘米的误差，
        # 而且"过期 5 秒的位置"画到地图上比不画更误导。
        age = float(depth.get("age") or 0.0)
        if age > MAX_AGE:
            q = None
            reason = "深度过期 %.1fs" % age

    for d in dets:
        tid = d.get("tid")
        item = {
            "tid": tid,
            "box": [int(v) for v in (d.get("box") or [0, 0, 0, 0])],
            "aim": (d.get("aim") or None),
            "score": d.get("score"),
            "labels": d.get("labels") or [],
            "locked": (locked_tid is not None and tid == locked_tid),
            "ok": False, "reason": reason,
        }
        if q is None:
            out.append(item)
            continue

        # 全分辨率：视频（左目原图）尺寸 / 原始内参 / 基线
        aw, ah = float(ai_wh[0]), float(ai_wh[1])
        w_full = float(depth.get("w") or aw)
        h_full = float(depth.get("h") or ah)
        # 方位角必须在**视频坐标**上用**原始内参**算：校正后的主点(cx_full)
        # 被 stereoRectify 挪过（本工程偏移很大），拿它当"正前方"会整体偏十几度。
        cam_fx = float(depth.get("cam_fx") or depth.get("focal_px") or 0.0)
        cam_cx = float(depth.get("cam_cx") or w_full * 0.5)
        cam_cy = float(depth.get("cam_cy") or h_full * 0.5)
        base_m = float(depth.get("baseline_m") or 0.0)

        # ---- 采样点 = **肩部中心** > 瞄准点 > 框中心（见 _pick_sample_pt）----
        #   用户 2026-11-01 要求"深度采样点优先取肩部中心"：腰腹（框中心）常被
        #   手臂/背包挡住，人走近时框被裁、中心还会滑到大腿；肩/颈根那一块正对
        #   相机、面积大，深度中位数最稳。
        u_ai, v_ai, src0, pair = _pick_sample_pt(d, aw, ah)
        # AI 像素 -> 视频全分辨率像素
        u_v = u_ai / aw * w_full
        v_v = v_ai / ah * h_full
        box_v = d.get("box") or [0, 0, 0, 0]
        try:
            box_w_v = max(1.0, (float(box_v[2]) - float(box_v[0])) / aw * w_full)
        except (TypeError, ValueError, IndexError):
            box_w_v = 1.0

        st = _probe_video_pt(q, depth, u_v, v_v, box_w_v, zlo, zhi, src0)
        if st is None:
            item["reason"] = "窗口内没有有效深度"
            out.append(item)
            continue
        if st.get("src") == "outside":
            item["reason"] = "不在深度视野内（人太靠画面边）"
            item["hu"] = round(st["hu"], 1)
            item["hv"] = round(st["hv"], 1)
            out.append(item)
            continue

        # ---- AI 跑在**右目**上时，先补视差再取一次 ----
        #   同一物点在右目像上的 u 比左目**小** f*B/z（2m 处约 35px），
        #   直接拿右目的 u 去取样/算方位会偏出去一点。先用右目的 u 粗取一次
        #   拿到 z，用 z 算视差，再挪到左目坐标精取。
        d_shift = 0.0
        if (not ai_on_left) and base_m > 0 and cam_fx > 0:
            d_shift = cam_fx * base_m / max(float(st["z"]), 0.05)
            st2 = _probe_video_pt(q, depth, u_v + d_shift, v_v,
                                  box_w_v, zlo, zhi, src0)
            if st2 is not None and st2.get("src") not in ("box", "outside"):
                st = st2
            u_v += d_shift

        dist = float(st["z"])
        if not (Z_SANE[0] <= dist <= Z_SANE[1]):
            item["reason"] = "距离越界 %.2fm" % dist
            item["dist_m"] = round(dist, 2)
            out.append(item)
            continue

        rel = to_base(dist, u_v, v_v, cam_fx, cam_cx, cam_cy, yaw_deg, pitch_deg)
        if rel is None:
            item["reason"] = "焦距不可用"
            out.append(item)
            continue

        conf = 1.0
        if st["spread"] > SPREAD_WARN:
            conf *= 0.6                       # 窗口里混了背景
        if st["src"] == "box":
            conf *= 0.8                       # 用的是兜底取样
        if st["src"] == "shoulder" and not pair:
            conf *= 0.9                       # 只看见一侧肩（侧身 / 遮挡）
        if int(st["n"]) < MIN_AIM_VALID * 2:
            conf *= 0.8                       # 有效像素偏少

        bearing = math.degrees(math.atan2(u_v - cam_cx, cam_fx))
        raw = {"x": rel["x"], "y": rel["y"], "up": rel["up"],
               "ground": rel["ground"], "range": rel["range"]}
        # 跨帧平滑：压住"关键点/SGBM 帧间抖动"和残留下来的云台摆动
        sm = _smooth_rel(tid, raw, time.monotonic()) if smooth else raw
        item.update({
            "ok": True,
            "reason": "",
            "dist_m": round(sm["range"], 2),
            "ground_m": round(sm["ground"], 2),
            "bearing_deg": round(bearing, 1),
            "bearing_world_deg": round(bearing + float(yaw_deg or 0.0), 1),
            "rel": {"x": round(sm["x"], 3), "y": round(sm["y"], 3)},
            # 原始（未平滑）也留下来：调参/对比用，前端画图只认 rel
            "rel_raw": {"x": round(rel["x"], 3), "y": round(rel["y"], 3)},
            "valid": int(st["n"]),
            "spread": round(float(st["spread"]), 2),
            "src": st["src"],
            "conf": round(conf, 2),
            "u_video": round(u_v, 1),
            # 采样点在**热力图**上的坐标（前端叠加到热力图上就能一眼看出
            # "采到的到底是不是人"）
            "hu": round(float(st.get("hu") or 0.0), 1),
            "hv": round(float(st.get("hv") or 0.0), 1),
            "depth_age": round(float(depth.get("age") or 0.0), 2),
        })
        out.append(item)
    return out


def _selftest():
    """合成一张热力图，验证量化解码 / 取样 / 坐标变换。"""
    if np is None:
        print("numpy 不可用: %s" % NP_ERR)
        return 1
    import sys
    zlo, zhi = 0.5, 8.0
    hw, hh = 256, 144
    # 左半画面：背景 6 m；中间 0.4~0.6 宽度是 2 m 的人
    z = np.full((hh, hw), 6.0, np.float32)
    z[30:130, 90:166] = 2.0
    llo, lhi = math.log(zlo), math.log(zhi)
    v = np.clip((np.log(np.clip(z, zlo, zhi)) - llo) / (lhi - llo), 0, 1)
    q = (1.0 + v * 254.0).astype(np.uint8)
    depth = {"ok": True, "t_done": 12345.0, "hw": hw, "hh": hh,
             "zlo": zlo, "zhi": zhi, "focal_px": 1448.5,
             "w": 1920, "h": 1080, "cx_full": 960.0, "cy_full": 540.0,
             "cam_fx": 1448.5, "cam_fy": 1447.9, "cam_cx": 960.0, "cam_cy": 540.0,
             "baseline_m": 0.048133, "img2rect": None,
             "age": 0.05,
             "heat": base64.b64encode(q.tobytes()).decode("ascii")}
    # AI 帧 960x540，人在正中间（框中心 u=480），框覆盖中间那一块
    dets = [{"tid": 7, "box": [330, 110, 630, 480], "aim": [480, 300], "score": 0.9}]
    r = match_targets(dets, depth, [960, 540], yaw_deg=0.0, pitch_deg=0.0,
                      smooth=False)
    t = r[0]
    ok = abs(t["dist_m"] - 2.0) < 0.12 and abs(t["bearing_deg"]) < 0.5
    print("  dist=%s ground=%s bearing=%s src=%s conf=%s" %
          (t["dist_m"], t["ground_m"], t["bearing_deg"], t["src"], t["conf"]))
    # 云台左转 30°：相对位置应往 +y（左）偏
    r2 = match_targets(dets, depth, [960, 540], yaw_deg=30.0, pitch_deg=0.0,
                       smooth=False)
    x, y = r2[0]["rel"]["x"], r2[0]["rel"]["y"]
    ok2 = (abs(math.degrees(math.atan2(y, x)) - 30.0) < 0.6)
    print("  yaw=30° -> rel=(%.2f, %.2f) 角度 %.1f°" %
          (x, y, math.degrees(math.atan2(y, x))))
    # 俯仰向下 20°：水平距离应该变短
    r3 = match_targets(dets, depth, [960, 540], yaw_deg=0.0, pitch_deg=20.0,
                       smooth=False)
    g = r3[0]["ground_m"]
    ok3 = g < t["ground_m"] - 0.05
    print("  pitch=20° -> ground=%.2f m (0° 时 %.2f)" % (g, t["ground_m"]))
    # AI 跑在右目上：u 要按视差 f*B/z 折算回左目（2m 处 ≈ 35px 全分辨率）
    dep2 = dict(depth, t_done=99999.0, baseline_m=0.048133)
    u_l = 133.0 / hw * 1920.0                    # 人在左目像上的 u（像素）
    d_px = 1448.5 * 0.048133 / 2.0               # 2m 的视差
    u_r_ai = (u_l - d_px) / 1920.0 * 960.0       # 换算到 AI(960 宽) 坐标
    dets2 = [{"tid": 8, "box": [u_r_ai - 170, 110, u_r_ai + 170, 480],
              "aim": [u_r_ai, 300]}]
    rr = match_targets(dets2, dep2, [960, 540], 0.0, 0.0, ai_on_left=False,
                       smooth=False)
    want = math.degrees(math.atan2(u_l - 960.0, 1448.5))
    ok4 = abs(rr[0]["bearing_deg"] - want) < 0.4
    print("  右目 u=%.1f -> bearing=%.2f° (应 %.2f°), dist=%s" %
          (u_r_ai, rr[0]["bearing_deg"] if rr[0]["ok"] else float("nan"),
           want, rr[0].get("dist_m")))
    # 肩部中点优先：把框向右挪到人外面（框中心落在背景 6m 上），
    # 但肩中点仍在人身上 -> 应取到 2m、src=shoulder。
    dets3 = [{"tid": 9, "box": [500, 110, 800, 480], "aim": [650, 300],
              "sh": [480, 250], "sh_pair": True}]
    r5 = match_targets(dets3, depth, [960, 540], 0.0, 0.0, smooth=False)
    t5 = r5[0]
    ok5 = (bool(t5.get("ok")) and t5.get("src") == "shoulder"
           and abs(t5["dist_m"] - 2.0) < 0.15)
    print("  肩中点优先: dist=%s src=%s （同一个人框中心落在背景上）" %
          (t5.get("dist_m"), t5.get("src")))
    # 采样点映射到热力图**外面**（人贴到画面最右）-> 必须报"不在深度视野"，
    # 不能靠被边界裁掉一半的窗口硬采（那采到的是背景，位置直接错）。
    dets4 = [{"tid": 11, "box": [860, 110, 940, 480], "aim": [1000, 300]}]
    r6 = match_targets(dets4, depth, [960, 540], 0.0, 0.0, smooth=False)
    t6 = r6[0]
    ok6 = (not t6.get("ok")) and ("视野" in (t6.get("reason") or ""))
    print("  出界保护: ok=%s reason=%s hu=%s" %
          (t6.get("ok"), t6.get("reason"), t6.get("hu")))
    ok = ok and ok2 and ok3 and ok4 and ok5 and ok6
    print("PASS" if ok else "FAIL")
    return 0 if ok else 2


if __name__ == "__main__":
    import sys
    sys.exit(_selftest())
