#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ai_overlay.py —— 把「人体检测 + 姿态关键点 + 危险动作」直接叠加进 mipi_webstream 的推流画面。

为什么这样做
  * 原来 9013 的做法是「从 9012 拉 MJPEG → 解码 → 推理 → 再编码 → 再推一路」，
    同一画面被编码/解码两次，还多一份网络流量与一路 MJPEG 服务。
  * 本模块挂在 9012 的编码线程里，**直接复用已经转好的 BGR 帧**：
    没有第二次编解码、没有第二路流，只多一个限频的推理线程。

开销控制
  * 画面源 = 原图（或 AI 关闭）时：`active()` 为假 → 既不推理也不绘制，零额外开销；
  * 画面源 = AI 标注时：编码线程只做「投递最新帧 + 按最近结果画几笔」，
    推理在独立线程按 `ai_fps` 限频跑，**不会拖慢视频帧率**。

降级
  * 模型或依赖缺失时只在 `status()` 里报告错误，绝不影响原有推流功能。
"""
from __future__ import annotations

import os
import itertools
import queue
import sys
import threading
import time

# 参数存档（与服务共用同一个 state.json，各写自己那一段）
try:
    if os.path.dirname(os.path.abspath(__file__)) not in sys.path:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import state_store
except Exception:                                        # noqa: BLE001
    state_store = None


# 可持久化的字段（模型路径/目录不存：万一模型被删了，启动参数还能兑回来）
_STATE_KEYS = ("enabled", "source", "ai_fps", "det_conf", "nms_thres",
               "kpt_conf", "max_persons", "roi_expand", "kpt_margin",
               "kpt_scale_max", "det_interval", "copy_frame", "show_skeleton",
               "show_score", "show_label", "show_hud", "skeleton_only",
               "zone", "tune", "preset", "spread_pose", "pose_budget", "pipeline")

# 模型档位。
#
# ⚠ 实测结论（别再走弯路）：
#   * 一级 det 降到 512 → 画面里较小的人**漏检**（反复实测“有人却报 0 人”）；
#   * 二级 pose 换成 ultralytics 原生导出的小尺寸模型（384/320）→ RKNN INT8 量化会把
#     **类别分支压成全 0、关键点置信度只剩零星几个值**（即使把 cv2/cv3/cv4/Concat
#     都改成 float16 也救不回来）→ 表现就是“框出来了但一根骨头都没有”。
#   所以模型保持原尺寸（精度最高那一套），“快”靠 **检测帧跳姿态**（spread_pose）：
#   两级串在同一帧会出现一个 45ms 的长尾帧（det 30 + pose 35）把帧率拖住，
#   拆开后每帧都是短帧 —— 实测 17fps → 26fps，代价是骨架滞后一帧（约 35ms）。
PRESETS = (
    {"id": "smooth", "name": "帧率优先",
     "det": "yolov8n-slim.rknn", "pose": "yolov8n-pose-hybrid.rknn",
     "spread": True,
     "note": "检测帧不跑姿态：约 26 fps，骨架滞后一帧"},
    {"id": "accurate", "name": "关节最准",
     "det": "yolov8n-slim.rknn", "pose": "yolov8n-pose-hybrid.rknn",
     "spread": False,
     "note": "每一帧都跑姿态：骨架最顺，约 17 fps"},
)


def default_ai_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    for p in ("/root/rk/ai",
              os.path.abspath(os.path.join(here, "..", "ai"))):
        if os.path.isdir(p):
            return p
    return "/root/rk/ai"


def _first_existing(*paths):
    for p in paths:
        if os.path.isfile(p):
            return p
    return paths[0]


def _first_existing_name(mdir, *names):
    """在模型目录里挑第一个存在的文件名（都不在就返回第一个名字）。"""
    for n in names:
        if os.path.isfile(os.path.join(mdir, n)):
            return n
    return names[0]


def _lower_priority(delta):
    """把**当前线程**的 nice 值调高（= 把 CPU 让给视频链路）。

    Linux 的 nice 是 per-thread 的，所以只影响调用它的那个线程。
    为什么要这个：AI 开到 50fps 后，推理/前处理线程会把 3 个编码线程挤走，
    MJPEG 的平均帧率看不出变化（58.7 vs 59.4），但**帧间隔抖动**从 0.68ms
    涨到 3.57ms（p99 19→25ms），观感就是“拖影 / 一顿一顿”。
    AI 是“尽力而为”，视频链路才是主业务，所以让它先让路。
    """
    try:
        os.nice(int(delta))
    except Exception:                                           # noqa: BLE001
        pass


# COCO-17 关键点里跟"头部"有关的编号
_HEAD_IDX = (0, 1, 2, 3, 4)      # 鼻、两眼、两耳
_FOOT_IDX = (15, 16)             # 两脚踝
_SHOULDER_IDX = (5, 6)
_HIP_IDX = (11, 12)
_KNEE_IDX = (13, 14)
_KPT_CONF = 0.30

# 人体比例（相对**身高** H，成人均值）—— 用来从可见关节反推“整个人有多高”。
#   没有它就只能看检测框，而人走近/走到画面边缘时框是被裁过的，
#   框高只是“可见部分”，据此判断“能不能全包”必然误判。
_BODY_SEG = (
    ("torso", 0.29),     # 肩中点 -> 髋中点
    ("thigh", 0.25),     # 髋 -> 膝
    ("shin", 0.23),      # 膝 -> 踝
)
_HEAD_UP = 0.07          # 眼睛（头中心）到头顶
_FOOT_DOWN = 0.05        # 踝到脚底
_HIP_Y = 0.47            # 髋在身高里的位置（从头顶往下算）
_AIM_MARGIN = 0.03       # 全包判定留的边距（占画面高的比例）


def _kpt_rows(kps):
    """把关键点统一成 [[x, y, conf], ...]（兼容 numpy / list）。"""
    if kps is None:
        return None
    try:
        return kps.tolist() if hasattr(kps, "tolist") else list(kps)
    except Exception:                                           # noqa: BLE001
        return None


def _kp(rows, idx, conf=_KPT_CONF):
    """一组关键点的平均位置；全都不可见返回 None。"""
    if not rows:
        return None
    pts = [rows[i] for i in idx
           if i < len(rows) and len(rows[i]) >= 3 and rows[i][2] >= conf]
    if not pts:
        return None
    return (sum(p[0] for p in pts) / len(pts),
            sum(p[1] for p in pts) / len(pts))


def _dist(a, b):
    dx, dy = a[0] - b[0], a[1] - b[1]
    return (dx * dx + dy * dy) ** 0.5


def _shoulder_center(rows, box=None, conf=_KPT_CONF):
    """两肩中点（颈根部）—— 深度采样点优先用它。返回 dict 或 None。

    为什么要单独给这个点（2026-11-01 用户要求「深度采样优先取肩部中心」）：
      * 框中心落在腰腹：人走近/走到画面边缘时框被裁，框中心会滑到大腿甚至框外；
      * 腰腹又常被手臂、背包、桌面挡住，深度很容易匹配到背景；
      * 肩部（颈根到胸口）面积大、朝向正对相机、离地面高不易被杂物遮挡，
        是整幅人体上**深度最稳**的一块；两肩一起取中点还能抵消单肩误检。

    只看见一侧肩（人侧身）时仍然返回那一侧的坐标，但 `pair=False`，
    上层据此给置信度打折 —— 侧身时中点本来就≈单肩，用比不用好。

    ⚠ 必须做**解剖位置校验**（2026-11-01 板上实测踩到）：姿态模型在
    遮挡/近距离时会把手肘、甚至大腿的点判成"肩"，实测出现过
    box=[26,162,805,538]（框高 376）而 sh=(611,483) —— 落在框下 1/7 处，
    拿它去采深度会采到身体前面的杂物，距离直接错掉。
    所以：肩必须**低于头、高于髋**，且横向落在框内合理范围，否则返回 None
    （上层自然退回瞄准点/框中心，宁可不用也不要用错的点）。
    """
    if not rows:
        return None
    pts = []
    for i in _SHOULDER_IDX:
        if i < len(rows) and len(rows[i]) >= 3 and rows[i][2] >= conf:
            pts.append(rows[i])
    if not pts:
        return None

    # ---- 框尺寸（用于相对位置校验）----
    bw = bh = 0.0
    try:
        if box is not None and len(box) >= 4:
            bw = abs(float(box[2]) - float(box[0]))
            bh = abs(float(box[3]) - float(box[1]))
    except Exception:                                       # noqa: BLE001
        bw = bh = 0.0

    # ---- 与头 / 髋的上下关系（最可靠的解剖约束）----
    #   ⚠ 这里全部用**绝对像素坐标**：有 head/hip 就用它们的 y，没有才用
    #     "框顶 + 比例" 估一个（早先版本把两者混着加，相当于把偏移算了两遍，
    #     结果正常的两肩被拒、误检到大腿的反而通过）。
    head = _kp(rows, _HEAD_IDX, conf)
    hip = _kp(rows, _HIP_IDX, conf)
    box_y0 = None
    try:
        box_y0 = float(box[1]) if (box is not None and len(box) >= 4) else None
    except Exception:                                       # noqa: BLE001
        box_y0 = None
    base_y = box_y0 if box_y0 is not None else 0.0
    y_lo = y_hi = None                       # 肩 y 的允许区间（绝对坐标）
    if head is not None:
        y_lo = head[1] + 0.02 * bh           # 不高于头（肩在颈根，比眼睛低）
    elif bh > 0:
        y_lo = base_y + 0.02 * bh            # 没有头部关键点：至少别在框顶之上
    if hip is not None:
        y_hi = hip[1] + 0.05 * bh            # 不低过髋
    elif bh > 0:
        y_hi = base_y + 0.55 * bh            # 没髋：肩不该跑到框中线以下
    if y_lo is not None and y_hi is not None and y_hi <= y_lo:
        y_lo = y_hi = None                   # 头髋关系本身不可信 -> 不校验 y

    def _ok(p):
        if p is None:
            return False
        x, y = p[0], p[1]
        if bw > 0 and box is not None:
            x0 = min(float(box[0]), float(box[2]))
            if not (x0 - 0.05 * bw <= x <= x0 + 1.05 * bw):
                return False
        if y_lo is not None and not (y_lo <= y <= y_hi):
            return False
        return True

    if len(pts) == 2:
        (x0, y0), (x1, y1) = (pts[0][0], pts[0][1]), (pts[1][0], pts[1][1])
        mid = ((x0 + x1) / 2.0, (y0 + y1) / 2.0)
        # 两肩跨度/高度差离谱 -> 其中一个多半是误检（常见：把手肘认成肩）
        bad = ((bw > 0 and abs(x1 - x0) > 0.85 * bw)
               or (bh > 0 and abs(y1 - y0) > 0.25 * bh))
        if not bad and _ok(mid):
            return {"pt": mid, "pair": True}
        # 有一侧不可信：留置信度更高、且位置合理的那条
        for p in sorted(pts, key=lambda q: -q[2]):
            if _ok((p[0], p[1])):
                return {"pt": (p[0], p[1]), "pair": False}
        return None
    p = pts[0]
    if _ok((p[0], p[1])):
        return {"pt": (p[0], p[1]), "pair": False}
    return None


def _body_size(rows, box_h, conf=_KPT_CONF):
    """按关节比例估算**完整人体**的身高（像素）。返回 (est_h, from_joints)。

    ``from_joints`` 很重要：为 False 时 est_h 只是“检测框高度”，
    而框可能被裁过（人近了/走到边上）——那种情况下 est_h 是**下界**，
    不能拿它下“整个人装得下”的结论。
    """
    est = []
    sh = _kp(rows, _SHOULDER_IDX, conf)
    hp = _kp(rows, _HIP_IDX, conf)
    kn = _kp(rows, _KNEE_IDX, conf)
    an = _kp(rows, _FOOT_IDX, conf)
    for name, ratio in _BODY_SEG:
        a, b = {"torso": (sh, hp), "thigh": (hp, kn),
                "shin": (kn, an)}[name]
        if a is None or b is None:
            continue
        d = _dist(a, b)
        if d > 2.0:
            est.append(d / ratio)
    hd = _kp(rows, _HEAD_IDX, conf)
    if hd is not None and an is not None:
        # 头中心 -> 踝 占身高的比例（1 - 头顶到眼 - 踝到脚底）
        d = abs(an[1] - hd[1])
        if d > 2.0:
            est.append(d / (1.0 - _HEAD_UP - _FOOT_DOWN))
    if not est:
        return (box_h if box_h > 0 else None), False
    est.sort()
    v = est[len(est) // 2]
    # ⚠ 不能直接 `max(v, box_h)`：检测框通常带 padding（比人还高一点），
    #   拿它当身高会把“其实装得下”判成“装不下” -> 永远锁头、人不居中。
    #   只有框高**明显**大于关节估计（>1.15 倍）才认为关节估计不可信。
    if box_h and box_h > v * 1.15:
        v = box_h
    return v, True


def _aim_plan(det, frame_wh=None, margin_ratio=_AIM_MARGIN,
              prev_can_full=None):
    """算这个人的瞄准点 —— 带“云台试探位移”再判断能否全包。

    用户要求：**能全包就锁人体几何中心，装不下就优先锁头。**

    怎么判断“能不能全包”（试探位移）：假设云台把瞄准点送到画面正中，
    那么人体其余点的位置 = 原坐标 + (画面中心 - 瞄准点)。先按关节比例
    估出**完整身高**（框可能被裁，框高只是可见部分），把头顶/脚底挪到
    你希望的位置，看它们是否还落在画面内（各留 margin）：
      * 能  -> 瞄人体几何中心（头脚中点），人会在画面里上下居中；
      * 不能（人比画面还高 / 太近 / 关键点不够算不出身高）-> 瞄头部。
    头部被上边框裁掉时“瞄头”没意义，退回框中心。

    ``prev_can_full`` 用来做**滞回**：切入宽松（span <= 画面高 − 2×边距），
    一旦全包了就放宽一点才退出（span <= 画面高 − 1×边距）。
    ⚠ 方向不能写反：早先写成“切入要求 0.85 倍”这种更严的阈值，
    导致明明放得下也一直锁头（人贴到底部、不居中）。

    返回 dict：aim / mode / full_now / can_full / head / est_h / shift。
    """
    b = det.get("box")
    # ⚠ 不要写 `det.get("box") or [...]`：AI 内部的 box 可能是 numpy 数组，
    #   `or` 会对数组求布尔值 → ValueError: truth value ... is ambiguous。
    #   只要画面里出现目标，status() 就会整条抛异常（云台侧显示"AI 状态读取失败"）。
    try:
        b = [float(v) for v in b] if b is not None else []
    except Exception:                                           # noqa: BLE001
        b = []
    if len(b) < 4:
        b = [0.0, 0.0, 0.0, 0.0]
    x1, y1, x2, y2 = b[0], b[1], b[2], b[3]
    center = ((x1 + x2) / 2.0, (y1 + y2) / 2.0)
    rows = _kpt_rows(det.get("kps"))

    head = _kp(rows, _HEAD_IDX)
    feet = _kp(rows, _FOOT_IDX)
    hip = _kp(rows, _HIP_IDX)
    shc = _shoulder_center(rows, b)

    fw = fh = 0
    try:
        if frame_wh and len(frame_wh) >= 2:
            fw, fh = int(frame_wh[0] or 0), int(frame_wh[1] or 0)
    except Exception:                                           # noqa: BLE001
        fw = fh = 0

    box_h = max(0.0, y2 - y1)
    est_h, from_joints = _body_size(rows, box_h)
    cut_top = y1 <= 2
    cut_bottom = fh > 0 and y2 >= fh - 3
    # 当前这一刻：头 + 脚都在画面里，且框没被上下边缘截断
    full_now = bool(head is not None and feet is not None
                    and not cut_top and not cut_bottom)

    # ---- 完整人体的上下边界（脚被裁时按比例补出来）----
    top = bottom = None
    if est_h:
        if head is not None:
            top = head[1] - _HEAD_UP * est_h
        elif not cut_top:
            top = y1
        else:
            top = (y1 if y1 > 0 else center[1] - est_h / 2.0)
        if feet is not None:
            bottom = feet[1] + _FOOT_DOWN * est_h
        elif hip is not None:
            bottom = hip[1] + (1.0 - _HIP_Y) * est_h
        else:
            bottom = top + est_h
    else:
        top, bottom = y1, y2
    body = (hip[0] if hip is not None else center[0], (top + bottom) / 2.0)
    span = max(1.0, bottom - top)

    # ---- 试探位移：把几何中心送到画面中心后，头顶/脚底会落在哪 ----
    can_full = False
    shift = (0.0, 0.0)
    if fh > 0:
        margin = max(8.0, margin_ratio * fh)
        # 框图被裁过又没关节可用 -> est_h 只是下界，不能据此说"装得下"
        known = bool(from_joints or (not cut_top and not cut_bottom))
        if known:
            # 切入：严格一点（上下各留边距）；已全包：放宽 1 个边距才退出
            lim = (fh - margin) if prev_can_full else (fh - 2.0 * margin)
            can_full = span <= lim
        dy = fh / 2.0 - body[1]
        shift = (fw / 2.0 - body[0] if fw > 0 else 0.0, dy)
    else:
        # 画面尺寸未知（早期帧）：退回"当前是否完整"
        can_full = full_now

    if can_full:
        aim, mode = body, "center"
    elif head is not None and not cut_top:
        aim, mode = head, "head"
    else:
        aim, mode = center, "box"
    return {
        "aim": (float(aim[0]), float(aim[1])),
        "mode": mode,
        "full_now": full_now,
        "can_full": bool(can_full),
        "head": head,
        # 肩部中点：深度采样点优先用它（见 _shoulder_center 的注释）
        "shoulder": (shc["pt"] if shc else None),
        "shoulder_pair": bool(shc and shc["pair"]),
        "est_h": (float(est_h) if est_h else None),
        "span": float(span),
        "shift": (float(shift[0]), float(shift[1])),
    }


def _aim_point(det, frame_wh=None):
    """兼容旧签名：返回 (aim, can_full, head)。

    ``aim``  = 建议瞄准点 (x, y) 像素；连框都没有时也不为 None（用框中心）
    ``can_full`` = 云台挪过去之后能不能把整个人装进画面
    ``head`` = 头部中心 (x, y) 或 None
    """
    p = _aim_plan(det, frame_wh)
    return p["aim"], p["can_full"], p["head"]


def _make_actions(zone, box_margin, rule_cls):
    """动作识别后端：**demo 分类器优先**，异常时退回几何规则。

    demo 分类器 = rk/ai/board/action_demo_cls.py，也就是 rk/web/action_demo.html
    里 `demoClassifier()` 的 Python 移植（两者数值对拍差 <5e-7）。
    它不依赖训练数据：每个类都是"人写的充分条件"，阈值按前级
    （YOLO-pose + EMA α≈0.55）**实际可达**的速度标定，所以上板一次就对。
    训练模型（rknn/npz）那条路等采到干净的 idle/run/handup 再启用。
    """
    try:
        from action_model import ActionEngine
        from action_demo_cls import DemoActionModel, DEMO_WINDOW
        am = DemoActionModel(t_len=32)
        print("[ai] 动作识别: demo 分类器 (窗口 %.3fs, %d 类)"
              % (DEMO_WINDOW, len(am.classes)))
        eng = ActionEngine(am, alert_polygon=zone, cooldown=2.0,
                           window=DEMO_WINDOW)
        # 与 model.tune 共享同一个 dict：网页上的"灵敏度"滑杆
        # (fall/run/swing/throw) 直接写 ActionEngine.tune，这样仍能生效。
        eng.tune = getattr(am, 'tune', {})
        return eng
    except Exception as e:                                      # noqa: BLE001
        print("[ai] demo 动作分类器不可用(%s)，退回几何规则" % e)
        return rule_cls(alert_polygon=zone, box_margin=box_margin)


class AiOverlay(object):
    """线程安全的 AI 叠加器。编码线程调 submit()/draw()，本类内部线程负责推理。"""

    def __init__(self, ai_dir=None, det_model=None, pose_model=None,
                 ai_fps=6.0, det_conf=0.35, nms_thres=0.45, kpt_conf=0.30,
                 max_persons=4, roi_expand=1.15, kpt_margin=0.15,
                 kpt_scale_max=1.2, det_interval=2, copy_frame=False,
                 spread_pose=True, pose_budget=2, pipeline=True,
                 source="raw", enabled=True,
                 zone=None, show_skeleton=True, show_score=True, show_label=True,
                 show_hud=False, skeleton_only=False, state_path=None, verbose=False):
        self.ai_dir = os.path.abspath(ai_dir or default_ai_dir())
        mdir = os.path.join(self.ai_dir, "models")
        self.model_dir = mdir
        # 模型档位（det + pose 一套）。显式传了模型路径就按路径走，否则自动挑档位。
        self.preset = "custom" if (det_model or pose_model) else self._auto_preset(mdir)
        p0 = self._preset_by_id(self.preset) or {}
        # 优先用精简版检测模型：输出只有 person 一类（少 6MB/帧的输出搬运，实测快 ~5ms）
        self.det_model = det_model or os.path.join(
            mdir, p0.get("det") or _first_existing_name(
                mdir, "yolov8n-slim.rknn", "yolov8n.rknn"))
        self.pose_model = pose_model or os.path.join(
            mdir, p0.get("pose") or _first_existing_name(
                mdir, "yolov8n-pose-384-hybrid.rknn", "yolov8n-pose-hybrid.rknn"))

        # 可在线调节的参数（页面 /api/ai 直接改）
        self.enabled = bool(enabled)
        self.source = str(source or "raw")          # raw | ai
        self.ai_fps = max(0.5, float(ai_fps))
        self.det_conf = float(det_conf)
        self.nms_thres = float(nms_thres)
        self.kpt_conf = float(kpt_conf)
        self.max_persons = int(max_persons)
        self.roi_expand = float(roi_expand)
        # 一级框对二级/三级的空间约束：关节只保留在「人体框 ± margin」范围内
        #   >=0: 超出即判为不可见（防远处鬼点画出骨架/误报动作）
        #   < 0: 不限制（旧行为）
        self.kpt_margin = float(kpt_margin)
        self.box_margin = float(kpt_margin)
        # 距框中心门限（挡鬼点的主力）：关节到框中心不得超过 kpt_scale_max×(框对角/2)
        self.kpt_scale_max = float(kpt_scale_max)
        # 一级检测跳帧（每 N 帧跑一次；中间帧用姿态框回写跟随人体）
        self.det_interval = max(1, int(det_interval))
        # 检测帧是否跳过姿态：两级串在同一帧会出现“长尾帧”(det+pose≈45ms)，
        # 拆开后每帧都是短帧，帧率明显上去（代价：那帧的骨架滞后一帧）
        self.spread_pose = bool(spread_pose)
        # 多人时的姿态预算：每帧最多跑几个人的姿态（<=0 = 不限制）。
        # 姿态是逐人串行的（N 人 = N × ~23ms），人多会把帧率拖垮；
        # 限成 2 后其余人沿用上一帧关节（框位移补偿），
        # 人数 <= 预算时与不限制完全一致。
        self.pose_budget = int(pose_budget or 0)
        # 前处理流水：一级 letterbox（~1ms）交给独立线程，与 NPU 推理重叠。
        # 板上实测 21.17 -> 18.69 ms/帧（+12%），见 rk/web/bench_gpu_pipe.py。
        # ⚠ 只在启动时生效（运行中改值不会重建线程，重启服务才切换）。
        self.pipeline = bool(pipeline)
        self._pre_q = queue.Queue(maxsize=1)
        # 是否在推理前拷贝整帧：不拷贝可省 ~2.5ms/帧，代价是编码线程可能
        # 已在同一数组上画了几笔标注（对检测影响可忽略）
        self.copy_frame = bool(copy_frame)
        self.show_skeleton = bool(show_skeleton)
        self.show_score = bool(show_score)
        self.show_label = bool(show_label)
        self.show_hud = bool(show_hud)
        # 纯骨骼模式：整帧涂黑，只留关节点/骨架（不带人体框与标签）—— 隐私场景用
        self.skeleton_only = bool(skeleton_only)
        self.verbose = bool(verbose)
        # 绘制函数在 _load() 里缓存（draw() 每帧都要用，不能每帧 import）
        self._draw_person = None
        self._draw_pose = None
        self.zone = list(zone or [])

        self.ok = False
        self.err = ""
        self.det_ms = 0.0
        self.pose_ms = 0.0
        self.run_ms = 0.0             # detector.run() 的墙钟（含两级前处理+推理+后处理）
        self.track_ms = 0.0           # 跟踪 + 动作判定
        self.sync_ms = 0.0            # 等新帧 / 取锁的耗时（跳帧时不计）
        self.measured_fps = 0.0        # 整套两级推理（YOLO）实际帧率
        self.fps_det = 0.0             # 其中一级人体检测实际执行帧率（跳帧时 < 前者）
        self.fps_pose = 0.0            # 其中二级姿态实际执行帧率（= 每帧都跑）
        self.infer_count = 0
        self.last_error = ""

        self.detector = None
        self.tracker = None
        self.actions = None

        self._lock = threading.Lock()
        # 重建检测器（切模型）时要挡住推理线程，免得正在跑推理的实例被 release 了
        self._det_lock = threading.RLock()
        self._frame = None            # 编码线程投递的最新帧（引用，不拷贝）
        self._seq = 0
        self._result = []             # 最近一次的标注结果
        self._result_t = 0.0
        self._seq_gen = itertools.count(1)   # submit() 用的原子序号
        # 瞄准点滞回：tid -> 上一帧“云台挪过去能否全包”
        #   临界尺寸上 head <-> 几何中心 会来回切，云台会“点头”
        self._aim_full = {}
        self._stats = {"n": 0, "t0": time.time(), "det_n": 0, "pose_n": 0}

        self._stop = threading.Event()
        self._thr = None

        # 恢复上次的 AI 设置（页面重连 / 服务重启后不用重新调一遍）
        self._state_path = state_path
        self._restore_state()

    # ------------------------------------------------------------------ 生命周期
    @property
    def active(self):
        """编码线程只需判断这个：假 = 完全不碰帧。

        source 三种取值：
          raw    = 不推理、不叠加（最省）
          detect = 只推理、不叠加（云端报警用：本地画面保持干净）
          ai     = 推理 + 把框/骨架画到推流帧上
        """
        return bool(self.enabled and self.source in ("ai", "detect"))

    def start(self):
        if self._thr is not None:
            return
        self._thr = threading.Thread(target=self._run, name="ai-overlay", daemon=True)
        self._thr.start()

    def stop(self):
        self._stop.set()

    def _preset_by_id(self, pid):
        for p in PRESETS:
            if p["id"] == pid:
                return p
        return None

    def _auto_preset(self, mdir):
        """默认档位：优先「极速」（能跑满帧率），缺模型再往回退。

        用户要的是帧率；想要更准在网页上点一下就行。
        """
        order = ("smooth", "accurate")
        for pid in order:
            p = self._preset_by_id(pid)
            if p and (os.path.isfile(os.path.join(mdir, p["det"]))
                      and os.path.isfile(os.path.join(mdir, p["pose"]))):
                return pid
        return "accurate"

    def _preset_list(self):
        """给网页用的档位列表（带文件是否存在、是不是当前档位）。"""
        out = []
        for p in PRESETS:
            out.append({"id": p["id"], "name": p["name"], "note": p["note"],
                        "det": p["det"], "pose": p["pose"],
                        "spread": bool(p.get("spread", True)),
                        "exists": os.path.isfile(os.path.join(self.model_dir, p["det"]))
                        and os.path.isfile(os.path.join(self.model_dir, p["pose"])),
                        "active": p["id"] == self.preset})
        return out

    def _load(self):
        """加载模型（只在需要时做一次）。"""
        board = os.path.join(self.ai_dir, "board")
        if board not in sys.path:
            sys.path.insert(0, board)
        try:
            from action_rules import ActionRecognizer          # noqa: WPS433
            from det_core import SimpleTracker, TwoStageDetector  # noqa: WPS433
            from det_core import draw_person, draw_pose        # noqa: WPS433
            # ★ 绘制函数缓存成属性：draw() 在**每个编码帧**都会调，
            #   以前那里每次都 `from det_core import ...` —— 走 import 锁 + 模块表查找，
            #   58fps 下每秒 58 次，实测把 MJPEG 帧间隔抖动从 1.07ms 抬到 6.66ms。
            self._draw_person = draw_person
            self._draw_pose = draw_pose
        except Exception as e:                                  # noqa: BLE001
            self.err = "导入 AI 模块失败(%s): %s" % (board, e)
            return False

        det = self._build(self.det_model, self.pose_model)
        if det is None:
            return False
        self.detector = det
        self.tracker = SimpleTracker()
        self.actions = _make_actions(self.zone, self.box_margin,
                                    ActionRecognizer)
        self.ok = True
        if not det.pose or not det.pose.ok:
            self.err = "姿态模型不可用(仅画人体框): %s" % (
                det.pose.err if det.pose else "未指定")
        print("[ai] 模型已加载: det=%s pose=%s (det %s / pose %s 输入, 档位 %s)"
              % ("OK" if det.det.ok else "FAIL",
                 "OK" if (det.pose and det.pose.ok) else "FAIL",
                 getattr(det, "det_size", 0), getattr(det, "pose_size", 0),
                 self.preset))
        try:
            # 模型对象已就位，把这一大批长寿命对象移出 GC 扫描集合。
            # 配合 mipi_webstream 里的 set_threshold，能消掉 run_ms 的偶发尖峰。
            import gc
            gc.freeze()
        except Exception:                                       # noqa: BLE001
            pass
        return True

    def _build(self, det_path, pose_path):
        """构造一套两级检测器；失败返回 None（不动现有实例）。"""
        from det_core import TwoStageDetector                   # noqa: WPS433
        det = TwoStageDetector(det_path, pose_path,
                               det_conf=self.det_conf, nms_thres=self.nms_thres,
                               kpt_conf=self.kpt_conf, max_persons=self.max_persons,
                               roi_expand=self.roi_expand,
                               kpt_margin=self.kpt_margin,
                               kpt_scale_max=self.kpt_scale_max,
                               det_interval=self.det_interval,
                               spread_pose=self.spread_pose,
                               pose_budget=self.pose_budget)
        if not det.det or not det.det.ok:
            self.err = "检测模型不可用: %s" % (det.det.err if det.det else "未指定")
            return None
        return det

    def switch_preset(self, preset):
        """切换模型档位（热切换：加载成功才替换，失败保持原样）。

        调用方是 HTTP 线程，推理线程可能正在用旧实例 —— 所以整段都在
        _det_lock 里做，推理线程要么先跑完这一帧，要么等新模型就位。
        """
        if not preset:
            return False
        p = self._preset_by_id(preset)
        det_path = self.det_model
        pose_path = self.pose_model
        new_id = preset
        if p is not None:
            if p["id"] == self.preset and self.detector is not None:
                return False                      # 已经是这个档位
            det_path = os.path.join(self.model_dir, p["det"])
            pose_path = os.path.join(self.model_dir, p["pose"])
            # 档位的核心区别就是“检测帧要不要同时跑姿态”
            self.spread_pose = bool(p.get("spread", self.spread_pose))
        else:
            # 也允许直接传文件名/路径（只换姿态那个）
            pose_path = preset if os.path.isabs(preset) else os.path.join(
                self.model_dir, preset)
            new_id = "custom"
        for path in (det_path, pose_path):
            if not os.path.isfile(path):
                self.err = "模型文件不存在: %s" % path
                return False
        if self.detector is None:
            # 启动阶段（恢复存档）还没加载过模型：只记住档位，_load() 时自然按它建
            self.det_model, self.pose_model, self.preset = det_path, pose_path, new_id
            return True
        with self._det_lock:
            new_det = self._build(det_path, pose_path)
            if new_det is None:
                return False
            old = self.detector
            self.detector = new_det
            self.det_model, self.pose_model, self.preset = det_path, pose_path, new_id
            # 换了模型，关节坐标系会跳一下，跟踪器重建避免上一段的轨迹污染
            try:
                from det_core import SimpleTracker            # noqa: WPS433
                self.tracker = SimpleTracker()
            except Exception:                                   # noqa: BLE001
                pass
            if self.actions is not None:
                self.actions.tracks.clear()
            self.err = ""
            self.ok = True
            try:
                if old is not None:
                    for m in (old.pose, old.det):
                        if m is not None:
                            m.release()
            except Exception:                                       # noqa: BLE001
                pass
        print("[ai] 已切换模型档位 -> %s (det %s / pose %s 输入)"
              % (self.preset, getattr(new_det, "det_size", 0),
                 getattr(new_det, "pose_size", 0)))
        return True

    # ------------------------------------------------------------------ 编码线程接口
    def submit(self, frame):
        """投递最新帧（只存引用；真正要推理时内部才拷贝）。

        ★ **不拿锁**。这个函数在**每个编码帧**都会被调，而 `self._lock` 也被
        推理线程（写结果）/前处理线程（取帧）/status() 用。哪怕每次只等几十微秒，
        在 58fps × 多个调用点上也足以把 MJPEG 帧间隔抖动抬到毫秒级。
        序号用 `itertools.count()` 的 next() 生成（CPython 里是原子的），
        所以 3 个编码线程并发调也不会拿到重复序号。
        丢一两帧（并发覆盖）无所谓：本来就是“最新值”语义。
        """
        if not self.active or frame is None:
            return
        self._frame = frame
        self._seq = next(self._seq_gen)

    def draw(self, frame):
        """把最近一次的标注画到 frame 上（就地）。无结果时原样返回。"""
        if not self.active or frame is None:
            return frame
        if self.source != "ai":          # detect: 只推理，不往推流帧上画
            return frame
        res = self._result                 # 无锁读引用（同上，不跟推理线程抢锁）
        if not res and not self.skeleton_only:
            # 没结果（画面里没人）时直接返回。这一行很关键：
            # 以前即使什么都没画也要先跑一次 `from det_core import ...`，
            # 而 draw() 在**每个编码帧**都被调，54~66fps 下就是每秒 50+ 次 import，
            # 实测导致 MJPEG 帧间隔 stdev 1.07 -> 6.66ms、p99 19 -> 33ms（看着卡/拖影），
            # 而且与 ai_fps 无关（20fps 时依然抖）—— 因为它是“每帧”成本，不是“每推理”成本。
            return frame
        draw_person, draw_pose = self._draw_person, self._draw_pose
        if draw_person is None:
            return frame

        if self.skeleton_only:
            return self._draw_skeleton_only(frame, res, draw_pose)
        if not res:
            return frame

        for d in res:
            level = d.get("risk", 0)
            if level >= 2:
                color, thick = (0, 0, 255), 3
            elif level >= 1:
                color, thick = (0, 165, 255), 3
            else:
                color, thick = (0, 255, 0), 2
            label = ""
            acts = d.get("actions") or []
            if self.show_label and acts:
                # 画面上的标签一律用英文: cv2.putText 画不了中文(会变成 "???")
                label = "%s %.0f%%" % (_act_en(acts[0]), acts[0]["score"] * 100)
                if len(acts) > 1:
                    label += "/" + _act_en(acts[1])
            tid = d.get("tid")
            if tid is not None:
                label = ("ID%d %s" % (tid, label)).strip()
            draw_person(frame, d["box"], d["score"], _ascii(label), color, thick,
                        kps=d.get("kps") if self.show_skeleton else None,
                        show_score=self.show_score)
            if self.show_label and acts:
                h = frame.shape[0]
                y = min(h - 6, int(d["box"][3]) + 18)
                for i, a in enumerate(acts[:2]):
                    cv2_put(frame, _ascii("%s %.0f%%" % (_act_en(a), a["score"] * 100)),
                            (int(d["box"][0]), y + i * 18), a["color"])
        if self.show_hud:
            self._draw_hud(frame, res)
        return frame

    def _draw_skeleton_only(self, frame, res, draw_pose):
        """纯骨骼（黑底）：新建一张黑图只画骨架，**不动原始帧**。

        ⚠ 这里必须新建，不能就地 `frame[:] = 0`：
          推理线程默认直接读同一块内存（`copy_frame=False`，见 submit()），
          一旦把原帧涂黑，AI 下一帧拿到的就是全黑画面 →
          检测不到人 → 反而一根骨头都画不出来（这就是“黑底有人却没骨架”的原因）。
        颜色仍按风险级给（绿/橙/红），点画大一圈，远处也看得清。
        """
        try:
            import numpy as np
            out = np.zeros_like(frame)
        except Exception:                                       # noqa: BLE001
            return frame
        for d in res:
            kps = d.get("kps")
            if kps is None:
                continue
            level = d.get("risk", 0)
            if level >= 2:
                color, thick = (0, 0, 255), 3
            elif level >= 1:
                color, thick = (0, 165, 255), 3
            else:
                color, thick = (0, 255, 0), 2
            draw_pose(out, kps, color=color, thickness=max(2, thick), radius=5)
        if self.show_hud:
            self._draw_hud(out, res)
        return out

    def _draw_hud(self, frame, res):
        """左下角信息条：YOLO 帧率 / 两级耗时 / 人数。

        画在推流帧上（不是页面上），所以用英文 —— cv2.putText 不支持中文。
        这里只读 self.* 的普通属性，在编码线程调用是安全的。
        """
        try:
            import cv2
            # 实际/目标：17.2/20 fps 一眼看出 AI 有没有跑满
            line1 = "YOLO %.1f/%.0f fps  det %.0fms  pose %.0fms" % (
                self.measured_fps, self.ai_fps, self.det_ms, self.pose_ms)
            line2 = "PERSONS %d" % len(res)
            ids = [d["tid"] for d in res if d.get("tid") is not None]
            if ids:
                line2 += "  ID " + ",".join(str(i) for i in ids)
            h = frame.shape[0]
            y1 = h - 38
            y2 = h - 14
            for txt, y, col in ((line1, y1, (0, 255, 160)), (line2, y2, (0, 255, 160))):
                cv2.putText(frame, txt, (10, y), cv2.FONT_HERSHEY_SIMPLEX,
                            0.5, (0, 0, 0), 3, cv2.LINE_AA)
                cv2.putText(frame, txt, (10, y), cv2.FONT_HERSHEY_SIMPLEX,
                            0.5, col, 1, cv2.LINE_AA)
        except Exception:                                       # noqa: BLE001
            pass

    # ------------------------------------------------------------------ 推理线程
    def _run(self):
        _lower_priority(4)          # 推理让路给编码/采集
        if not self._load():
            print("[ai] 未启用: %s" % self.err, file=sys.stderr)
            return
        if self.pipeline:
            # 前处理（letterbox ~1ms）交给独立线程，与 NPU 推理重叠。
            # 实测 21.17 -> 18.69 ms/帧（+12%）；见 rk/web/bench_gpu_pipe.py。
            threading.Thread(target=self._pre_loop, daemon=True,
                             name="ai-pre").start()
        last_seq = -1
        while not self._stop.is_set():
            if not self.active:
                time.sleep(0.1)
                continue
            t0 = time.time()
            prepared = None
            if self.pipeline:
                try:
                    fr, prepared, sq = self._pre_q.get(timeout=0.2)
                except queue.Empty:
                    continue
                if sq == last_seq:
                    continue
            else:
                fr, sq = self._frame, self._seq      # 无锁读（引用+整数，原子）
                if fr is None or sq == last_seq:
                    time.sleep(0.005)
                    continue
            last_seq = sq
            # 默认不拷贝：编码线程最多在同一块内存上画几笔，对检测影响可忽略；
            # 要“绝对干净”就把 copy_frame 打开（多花 ~2.5ms/帧）。
            img = fr.copy() if self.copy_frame else fr
            try:
                # _det_lock：推理期间不许换模型（switch_pose 会 release 旧实例）
                t1 = time.time()
                with self._det_lock:
                    dets = self.detector.run(img, prepared)
                    t2 = time.time()
                    # frame_size 用来把**归一化**的警戒区换算成像素 ——
                    # 判定用脚踝关键点(原图像素)，不换算的话越界永远不触发。
                    dets = self.tracker.update(t0, dets)
                    dets = self.actions.update(t0, dets,
                                               frame_size=(img.shape[1], img.shape[0]))
                t3 = time.time()
            except Exception as e:                                  # noqa: BLE001
                self.last_error = "%s: %s" % (type(e).__name__, e)
                if self.verbose:
                    print("[ai] 推理异常: %s" % self.last_error, file=sys.stderr)
                time.sleep(0.2)
                continue
            self.run_ms = (t2 - t1) * 1000.0
            self.track_ms = (t3 - t2) * 1000.0
            self.sync_ms = (t1 - t0) * 1000.0

            with self._lock:
                self._result = dets
                self._result_t = t0
            self.det_ms = self.detector.det.infer_ms if self.detector.det else 0.0
            self.pose_ms = self.detector.pose.infer_ms if self.detector.pose else 0.0
            self.infer_count += 1
            st = self._stats
            st["n"] += 1
            span = time.time() - st["t0"]
            if span >= 2.0:
                self.measured_fps = st["n"] / span
                # 一级检测会跳帧(det_interval)，所以单独算它的真实执行帧率
                dst = self.detector.stat if self.detector is not None else {}
                dn = dst.get("det_n", 0)
                pn = dst.get("pose_n", 0)
                self.fps_det = max(0.0, (dn - st["det_n"]) / span)
                self.fps_pose = max(0.0, (pn - st["pose_n"]) / span)
                st["det_n"], st["pose_n"] = dn, pn
                st["n"] = 0
                st["t0"] = time.time()

            rest = 1.0 / max(0.5, self.ai_fps) - (time.time() - t0)
            if rest > 0:
                time.sleep(rest)

    def _pre_loop(self):
        """AI 流水的前处理线程：对最新帧做一级 letterbox，交给推理线程。

        三个要点：
          * 双缓冲：`pipe0` / `pipe1` 轮流用。推理线程正在读上一块画布时，
            本线程写另一块，否则会把正在喂给 NPU 的数据盖掉。
          * 队列只留 1 个：推理端还没消费时**不再生产**（直接把新帧丢掉），
            否则延迟会累积，画面越跟越不上。
          * **不拿 `_det_lock`**：主线程一轮 run() 要 18~20ms，抢锁就等于没流水。
            `prepare()` 只读构造后不变量（INPUT / interp），无需保护。
        """
        k = 0
        last = -1
        _lower_priority(6)          # 前处理比推理更次要
        while not self._stop.is_set():
            if not self.active or self.detector is None:
                time.sleep(0.05)
                continue
            fr, sq = self._frame, self._seq      # 无锁读（同上，不抢锁）
            if fr is None or sq == last:
                time.sleep(0.005)
                continue
            last = sq
            try:
                pack = self.detector.prepare(fr, slot="pipe%d" % (k & 1))
            except Exception as e:                              # noqa: BLE001
                self.last_error = "%s: %s" % (type(e).__name__, e)
                time.sleep(0.05)
                continue
            k += 1
            try:
                # 队列满就**阻塞等**，不要忙轮询：原来每 3ms 醒一次，
                # 一次不下就空转一次，白白抢了一个核的调度。
                self._pre_q.put((fr, pack, sq), timeout=0.3)
            except queue.Full:
                pass

    # ------------------------------------------------------------------ 状态 / 调参
    def status(self):
        with self._lock:
            res = list(self._result)
            rt = self._result_t
        # 画面尺寸：detections 里的 box 是**像素坐标**，云台追踪要拿它
        # 归一化成"偏离画面中心多少"，所以必须把喂给 AI 那一帧的宽高一起给出。
        fr = self._frame
        frame_wh = None
        try:
            if fr is not None and hasattr(fr, "shape"):
                frame_wh = [int(fr.shape[1]), int(fr.shape[0])]
        except Exception:                                       # noqa: BLE001
            frame_wh = None
        dets = []
        for d in res:
            kps = d.get("kps")
            n_kpt = 0
            if kps is not None:
                try:
                    n_kpt = int((kps[:, 2] > 0).sum())
                except Exception:                               # noqa: BLE001
                    n_kpt = 0
            aim, full, head = None, False, None
            plan = None
            try:
                # 滞回：上一帧已经能全包 -> 用正常阈值维持；否则要更严格才切回来
                prev = self._aim_full.get(d.get("tid"))
                plan = _aim_plan(d, frame_wh, prev_can_full=prev)
                aim = plan["aim"]
                full = plan["can_full"]
                head = plan["head"]
                if d.get("tid") is not None:
                    self._aim_full[d.get("tid")] = bool(plan["can_full"])
            except Exception:                               # noqa: BLE001
                # 瞄准点算不出来不该让整个 /api/ai 挂掉（云台会显示"读取失败"）
                pass
            dets.append({
                "tid": d.get("tid"),
                "box": [int(v) for v in d.get("box", [0, 0, 0, 0])],
                "score": round(float(d.get("score", 0)), 3),
                "risk": d.get("risk", 0),
                "n_kpt": n_kpt,
                # 给云台追踪用的"瞄准点"：
                #   能全包 = 人体几何中心（头脚中点）
                #   装不下 = 头部中心（头被上边框裁掉才退回框中心）
                "aim": ([int(round(aim[0])), int(round(aim[1]))]
                        if aim else None),
                "aim_head": bool(plan and plan["mode"] == "head"),
                "aim_mode": ({"head": "头部", "center": "几何中心",
                              "box": "框中心"}[plan["mode"]]
                             if plan else None),
                # full = 当前这一刻是否完整可见（旧语义，页面显示用）
                # can_full = 云台挪过去以后能不能全包（决定瞄哪）
                "full": bool(plan["full_now"]) if plan else bool(full),
                "can_full": bool(full),
                "est_h": (int(round(plan["est_h"]))
                          if plan and plan["est_h"] else None),
                "shift": ([int(round(plan["shift"][0])),
                           int(round(plan["shift"][1]))] if plan else None),
                "head": ([int(round(head[0])), int(round(head[1]))]
                         if head else None),
                # 肩部中点：person_dist 的深度采样点**优先**取这里。
                #   框中心会随「框被裁」滑动、腰腹常被手臂/背包挡住；
                #   肩部朝向正对相机、面积大，是整幅人体上深度最稳的一块。
                "sh": ([int(round(plan["shoulder"][0])),
                        int(round(plan["shoulder"][1]))]
                       if (plan and plan.get("shoulder")) else None),
                "sh_pair": bool(plan and plan.get("shoulder_pair")),
                "labels": [a["cn"] for a in (d.get("actions") or [])],
                "labels_en": [_act_en(a) for a in (d.get("actions") or [])],
            })
        ev = []
        if self.actions is not None:
            for e in list(self.actions.events)[-10:]:
                ev.append({"t": round(e["t"], 2), "tid": e["tid"],
                           "label": e["label"], "cn": e.get("cn"), "en": e.get("en"),
                           "score": round(e["score"], 2)})
        return {
            "ok": self.ok,
            "err": self.err,
            "last_error": self.last_error,
            "enabled": self.enabled,
            "source": self.source,
            "active": self.active,
            "frame": frame_wh,
            "fps": round(self.measured_fps, 1),
            "fps_target": round(self.ai_fps, 1),
            "fps_det": round(self.fps_det, 1),
            "fps_pose": round(self.fps_pose, 1),
            "infer_count": self.infer_count,
            "det_ms": round(self.det_ms, 1),
            "pose_ms": round(self.pose_ms, 1),
            "run_ms": round(self.run_ms, 1),
            "track_ms": round(self.track_ms, 1),
            "sync_ms": round(self.sync_ms, 1),
            "persons": len(res),
            "age_ms": round((time.time() - rt) * 1000.0, 1) if rt else None,
            "detections": dets,
            "events": ev,
            "tune": dict(self.actions.tune) if self.actions else {},
            "zone": self.zone,
            "det_conf": round(self.det_conf, 3),
            "nms_thres": round(self.nms_thres, 3),
            "det_interval": self.det_interval,
            "copy_frame": self.copy_frame,
            "spread_pose": self.spread_pose,
            "pose_budget": self.pose_budget,
            "pipeline": self.pipeline,
            "kpt_conf": round(self.kpt_conf, 3),
            "kpt_margin": round(self.kpt_margin, 3),
            "kpt_scale_max": round(self.kpt_scale_max, 3),
            "roi_expand": round(self.roi_expand, 3),
            "kpt_dropped": (self.detector.stat.get("kpt_dropped", 0)
                            if self.detector is not None else 0),
            "kpt_far": (self.detector.stat.get("kpt_far", 0)
                        if self.detector is not None else 0),
            "max_persons": self.max_persons,
            "show_skeleton": self.show_skeleton,
            "show_score": self.show_score,
            "show_label": self.show_label,
            "show_hud": self.show_hud,
            "skeleton_only": self.skeleton_only,
            "pose_preset": self.preset,
            "preset": self.preset,
            "presets": self._preset_list(),
            "models": {"det": self.det_model, "pose": self.pose_model,
                       "det_size": getattr(self.detector, "det_size", None),
                       "pose_size": getattr(self.detector, "pose_size", None)},
        }

    def apply(self, patch):
        """在线调参：enabled/source/ai_fps/阈值/标注开关/灵敏度/警戒区。"""
        if not isinstance(patch, dict):
            return self.status()
        if "enabled" in patch:
            self.enabled = bool(patch["enabled"])
        if "source" in patch:
            src = str(patch["source"]).lower()
            if src in ("raw", "ai", "detect"):
                self.source = src
        for k in ("show_skeleton", "show_score", "show_label", "show_hud",
                  "skeleton_only"):
            if k in patch:
                setattr(self, k, bool(patch[k]))
        if "ai_fps" in patch:
            # 上限放开到 60: 原来卡在 30 会掩盖真实性能（双核 NPU 后 det 单帧仅 ~17ms，
            # 理论上限已高于 30）。真正的天花板由 run_ms 决定，不需要人为限制。
            self.ai_fps = max(0.5, min(60.0, float(patch["ai_fps"])))
        if "det_conf" in patch:
            self.det_conf = max(0.05, min(0.95, float(patch["det_conf"])))
            if self.detector is not None:
                self.detector.det_conf = self.det_conf
        if "nms_thres" in patch:
            self.nms_thres = max(0.05, min(0.95, float(patch["nms_thres"])))
            if self.detector is not None:
                self.detector.nms_thres = self.nms_thres
        if "kpt_conf" in patch:
            self.kpt_conf = max(0.0, min(0.95, float(patch["kpt_conf"])))
            if self.detector is not None:
                self.detector.kpt_conf = self.kpt_conf
        if "max_persons" in patch:
            self.max_persons = max(1, min(16, int(patch["max_persons"])))
            if self.detector is not None:
                self.detector.max_persons = self.max_persons
        if "kpt_margin" in patch:
            # 一级框的空间约束（二级关键点 + 三级动作判定同步生效）
            self.kpt_margin = max(-1.0, min(2.0, float(patch["kpt_margin"])))
            self.box_margin = self.kpt_margin
            if self.detector is not None:
                self.detector.kpt_margin = self.kpt_margin
            if self.actions is not None:
                self.actions.box_margin = self.box_margin
        if "roi_expand" in patch:
            # 二级 ROI 的外扩倍数：越小，姿态只在框附近找
            self.roi_expand = max(1.0, min(2.0, float(patch["roi_expand"])))
            if self.detector is not None:
                self.detector.roi_expand = self.roi_expand
        if "kpt_scale_max" in patch:
            # 距框中心门限（挡鬼点主力）：0 = 关闭
            self.kpt_scale_max = max(0.0, min(5.0, float(patch["kpt_scale_max"])))
            if self.detector is not None:
                self.detector.kpt_scale_max = self.kpt_scale_max
        if "det_interval" in patch:
            # 一级检测跳帧：1=每帧都检测（最准最慢），N 越大越快
            self.det_interval = max(1, min(10, int(patch["det_interval"])))
            if self.detector is not None:
                self.detector.det_interval = self.det_interval
        if "copy_frame" in patch:
            self.copy_frame = bool(patch["copy_frame"])
        if "spread_pose" in patch:
            # 检测帧是否跳过姿态（帧率与骨架平滑度的取舍）
            self.spread_pose = bool(patch["spread_pose"])
            if self.detector is not None:
                self.detector.spread_pose = self.spread_pose
        if "pose_budget" in patch:
            # 每帧最多跑几个人的姿态（0 = 不限制）；人多时防止帧率线性下降
            self.pose_budget = max(0, min(16, int(patch["pose_budget"])))
            if self.detector is not None:
                self.detector.pose_budget = self.pose_budget
        if "pipeline" in patch:
            # 前处理流水开关：只有启动时读，运行中改需要重启服务才生效
            self.pipeline = bool(patch["pipeline"])
        if "preset" in patch and patch["preset"]:
            self.switch_preset(patch["preset"])
        if "pose_preset" in patch and patch["pose_preset"]:
            self.switch_preset(patch["pose_preset"])
        if "zone" in patch:
            self.zone = list(patch["zone"] or [])
            if self.actions is not None:
                self.actions.alert_polygon = self.zone
        if "tune" in patch and isinstance(patch["tune"], dict) and self.actions is not None:
            for k, v in patch["tune"].items():
                try:
                    self.actions.tune[k] = float(v)
                except (TypeError, ValueError):
                    pass
        if self.source == "raw":
            with self._lock:                 # 切回原图: 清掉残留结果, 不再画
                self._result = []
            # 顺手把统计归零, 免得页面上还显示着停止前的帧率
            self.measured_fps = 0.0
            self._stats["n"] = 0
            self._stats["t0"] = time.time()
        self._save_state()
        return self.status()

    # ------------------------------------------------------------ 参数存档
    def _state_snapshot(self):
        """当前设置的快照（只含白名单字段）。"""
        snap = {}
        for k in _STATE_KEYS:
            if k == "tune":
                snap[k] = dict(self.actions.tune) if self.actions is not None else {}
            elif k == "zone":
                snap[k] = [list(p) for p in (self.zone or [])]
            else:
                snap[k] = getattr(self, k, None)
        return snap

    def _save_state(self):
        if state_store is not None and self._state_path:
            state_store.put(self._state_path, "ai", self._state_snapshot())

    def _restore_state(self):
        if state_store is None or not self._state_path:
            return
        st = state_store.get(self._state_path, "ai")
        if not st:
            return
        keep = {k: v for k, v in st.items() if k in _STATE_KEYS and v is not None}
        if not keep:
            return
        try:
            self.apply(keep)                 # 复用同一套校验/夹取逻辑
            print("[ai] 已恢复上次的 AI 设置: %s" % ", ".join(sorted(keep)))
        except Exception as e:                                   # noqa: BLE001
            print("[ai] 恢复上次设置失败: %s" % e, file=sys.stderr)


def cv2_put(img, text, org, color):
    """小工具: 画一行带描边的标签。

    ⚠ cv2.putText 只支持 ASCII，传中文进去会渲染成一串 "???" ——
    所以调用方必须传英文（动作名走 `_act_en()`）。
    """
    try:
        import cv2
        cv2.putText(img, text, org, cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(img, text, org, cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 2, cv2.LINE_AA)
    except Exception:  # noqa: BLE001
        pass


def _act_en(a):
    """动作的英文名（画图用）：en -> label -> cn，兼容旧结果字段。"""
    return a.get("en") or a.get("label") or a.get("cn") or "?"


def _ascii(s):
    """只保留 ASCII 字符。

    cv2.putText 用的是 Hershey 字体，根本没有汉字字形 —— 直接传中文
    画出来就是一串 "???"。这里是最后一道保险：任何进图的文字先过滤。
    """
    return "".join(ch for ch in str(s) if ord(ch) < 128) or "?"
