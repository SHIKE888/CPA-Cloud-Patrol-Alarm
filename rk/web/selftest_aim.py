# -*- coding: utf-8 -*-
"""瞄准点单点化自检：验证"永远人体几何中心"以及"裁切时连续不跳"。

背景（2026-11-01 用户要求）：原来 aim 在「几何中心 / 头部 / 框中心」三态之间
切换，三者的 y 相差人体高度的 0.2~0.4，每次切换都是一次阶跃 —— 云台追着它
来回跑，就是"瞄准后周期上下摆动"的燃料。改成永远用几何中心。

验证四件事：
  1. 全身可见时 aim == (头顶+脚底)/2；
  2. 脚出框时 aim 仍落在躯干偏下（不能跳回头部、也不能飞出画面）；
  3. 头出框时 aim 仍在画面内；
  4. **连续性**：人慢慢走近（身高 120 -> 900 像素、脚逐渐出画），aim 的 y
     相邻两档跳变 < 2% 画面高 —— 这才是"云台不再摆"的根本。

跑法：python selftest_aim.py
（Windows 控制台是 GBK，中文会花；用 PYTHONIOENCODING=utf-8 或重定向到文件）
"""
import sys

try:
    from ai_overlay import _aim_plan, AiOverlay
except Exception as e:                                  # noqa: BLE001
    print("导入 ai_overlay 失败: %s: %s" % (type(e).__name__, e))
    sys.exit(1)

FW, FH = 960, 540          # AI 帧（左半幅缩放到 960x540）


def rows(d):
    """{idx: (x, y, conf)} -> COCO-17 的 17 行 [[x,y,c], ...]"""
    out = []
    for i in range(17):
        if i in d:
            x, y, c = d[i]
            out.append([float(x), float(y), float(c)])
        else:
            out.append([0.0, 0.0, 0.0])
    return out


def person(cx, head_y, foot_y):
    """按身高 H = foot_y - head_y 造一副完整骨架（比例取成人均值）。"""
    H = foot_y - head_y
    return {
        0: (cx, head_y + 0.07 * H, 0.9),                     # 鼻（头中心）
        5: (cx - 0.18 * H, head_y + 0.29 * H, 0.85),         # 左肩
        6: (cx + 0.18 * H, head_y + 0.29 * H, 0.85),         # 右肩
        11: (cx - 0.08 * H, head_y + 0.53 * H, 0.85),        # 左髋
        12: (cx + 0.08 * H, head_y + 0.53 * H, 0.85),        # 右髋
        13: (cx - 0.08 * H, head_y + 0.78 * H, 0.8),         # 左膝
        14: (cx + 0.08 * H, head_y + 0.78 * H, 0.8),         # 右膝
        15: (cx - 0.08 * H, foot_y, 0.8),                    # 左踝
        16: (cx + 0.08 * H, foot_y, 0.8),                    # 右踝
    }


def make_det(kps, box=None):
    if box is None:
        xs = [p[0] for p in kps.values()]
        ys = [p[1] for p in kps.values()]
        box = [min(xs) - 10, min(ys) - 10, max(xs) + 10, max(ys) + 10]
    return {"box": box, "kps": rows(kps)}


ok = True

# ---------- 1. 全身可见 ----------
H0 = 360                                # 头顶 120，脚底 480
k = person(480, 120, 480)
p = _aim_plan(make_det(k), (FW, FH))
exp1 = 0.5 * (120 + (480 + 0.05 * H0))   # 头顶(120) 与 脚底(480+0.05H) 的中点
print("1) 全身可见: aim=(%.1f, %.1f) mode=%s can_full=%s  期望 y=%.1f"
      % (p["aim"][0], p["aim"][1], p["mode"], p["can_full"], exp1))
if not (abs(p["aim"][1] - exp1) < 6 and p["mode"] == "center"):
    ok = False
    print("   [X] 不是几何中心")

# ---------- 2. 脚出框（踝不可见，框底=画面底）----------
k2 = dict(k)
k2.pop(15)
k2.pop(16)
box2 = [330, 120 - 0.06 * H0, 630, FH]
p2 = _aim_plan(make_det(k2, box=box2), (FW, FH))
head_y = 120 + 0.07 * H0
print("2) 脚出框:   aim=(%.1f, %.1f) mode=%s  (头部 y=%.0f，画面高 %d)"
      % (p2["aim"][0], p2["aim"][1], p2["mode"], head_y, FH))
# 必须明显低于头部、且不能飞出画面下沿
if not (head_y + 40 < p2["aim"][1] < FH and p2["mode"] == "infer"):
    ok = False
    print("   [X] 脚出框时跳到了头部或飞出了画面")

# ---------- 3. 头出框（鼻不可见，框顶=画面上沿）----------
k3 = dict(k)
k3.pop(0)
p3 = _aim_plan(make_det(k3, box=[330, 0, 630, 480]), (FW, FH))
print("3) 头出框:   aim=(%.1f, %.1f) mode=%s  (应在 0~%d 之内)"
      % (p3["aim"][0], p3["aim"][1], p3["mode"], FH))
if not (0 < p3["aim"][1] < FH and p3["mode"] == "infer"):
    ok = False
    print("   [X] 头出框时位置不合理")

# ---------- 4. 没有姿态关键点 ----------
p4 = _aim_plan({"box": [330, 110, 630, 480], "kps": None}, (FW, FH))
exp4 = 0.5 * (110 + 480)
print("4) 无关键点: aim=(%.1f, %.1f) mode=%s  期望 y=%.1f"
      % (p4["aim"][0], p4["aim"][1], p4["mode"], exp4))
if not (abs(p4["aim"][1] - exp4) < 1 and p4["mode"] == "box"):
    ok = False
    print("   [X] 退回框中心不对")

# ---------- 5. 连续性：人慢慢走近 ----------
print("5) 连续走近（身高 120 -> 900px，脚逐渐出画）：")
prev = None
maxjump = 0.0
for H in range(120, 920, 20):
    foot_y = 440.0 + max(0.0, (H - 360) * 0.8)     # 人越近脚越往下压出画面
    head_y = foot_y - H
    kk = person(480, head_y, foot_y)
    box = [480 - 0.30 * H, max(0.0, head_y - 0.06 * H),
           480 + 0.30 * H, min(FH, foot_y + 0.05 * H)]
    pp = _aim_plan(make_det(kk, box=box), (FW, FH))
    y = pp["aim"][1]
    if prev is not None:
        maxjump = max(maxjump, abs(y - prev) / FH)
    prev = y
print("   相邻两档 aim 最大跳变 = %.2f%% 画面高（要求 < 2%%）" % (100.0 * maxjump))
if maxjump > 0.02:
    ok = False
    print("   [X] aim 还在跳")

# ---------- 6/7. 瞄准点帧间平滑（远距离目标抖动）----------
#   直接用 AiOverlay._smooth_aim，造一个只有状态字段的假对象即可。
class _Fake(object):
    _AIM_EMA = AiOverlay._AIM_EMA
    _AIM_STEP_FRAC = AiOverlay._AIM_STEP_FRAC

    def __init__(self):
        self._aim_smooth = {}


fake = _Fake()


def sm(tid, x, y):
    return AiOverlay._smooth_aim(fake, tid, (x, y), (FW, FH))


# 6) 远距离：框高 ~60px 的人静止站着，aim 每帧 ±5px 来回抖
#   注：交替方波是 EMA 的最坏情况，稳态摆幅 = 2A*a/(2-a)（a=0.4 -> 2.5px）。
#   判据不用"压到 0"，而是**必须远小于云台死区**（pitch 死区 0.05 归一化
#   = 13.5px），否则云台还会追着它动。
seq = [270 + (5 if i % 2 else -5) for i in range(30)]
out = [sm(1, 480, y)[1] for y in seq]
pp6 = max(out[10:]) - min(out[10:])
print("6) 静止远目标(±5px 抖): 平滑后摆幅 %.2f px（原 10.0px，死区 13.5px，要求 < 5）"
      % pp6)
if pp6 >= 5.0:
    ok = False
    print("   [X] 抖动没被压住")

# 7) 真实移动要跟得上：aim 从 270 匀速走到 220（50px / 1s @30fps）
fake2 = _Fake()
ys = [270 - 50.0 * i / 30.0 for i in range(31)]
last = None
for y in ys:
    last = AiOverlay._smooth_aim(fake2, 2, (480, y), (FW, FH))[1]
lag = abs(last - ys[-1])
print("7) 真实移动 50px/s: 1 秒后滞后 %.1f px（要求 < 8）" % lag)
if lag >= 8.0:
    ok = False
    print("   [X] 跟得太慢")

print("\nPASS" if ok else "\nFAIL")
raise SystemExit(0 if ok else 1)
