#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""action_rules.py —— 基于骨架时序的「危险动作」识别（纯规则 + 状态机，无需额外模型）。

设计取舍
  * 只用 17 关键点 + 时间序列，不训练分类网络，部署零成本、可解释、易调阈值；
  * 每条规则都要求「持续时长」而不是单帧命中，避免抖动误报；
  * 所有阈值都以人体框高（≈身高）归一化，分辨率变化时不失效。

可识别动作：
    fall      跌倒（躯干突然水平 + 髋部高度骤降）
    lying     倒地/躺卧不起（水平姿态持续）
    climb     攀爬/翻越（双手过肩线上举 + 髋部快速抬升 / 脚高于髋）
    run       奔跑（髋部水平速度持续偏高）
    fight     激烈肢体冲突（腕部速度极高）
    intrude   越界（脚部关键点落入警戒多边形）
    handup    举手求救（腕高于肩且持续）
    squat     下蹲（髋部接近膝部高度）    swing     挥砍（**单侧**手臂高速大位移，与 fight 的双手高频区分）
    throw     投掷（手腕快速**向上**挥动且过肩）
    photo     拍照/手持设备（双手举到脸前、彼此靠近、保持不动）"""
from __future__ import annotations

import math
from collections import deque

# 关键点索引
NOSE = 0
LS, RS = 5, 6
LE, RE = 7, 8
LW, RW = 9, 10
LH, RH = 11, 12
LK, RK = 13, 14
LA, RA = 15, 16

LEVEL_INFO = 0     # 仅记录
LEVEL_WARN = 1     # 提醒（橙）
LEVEL_ALARM = 2    # 报警（红）

# label -> (中文名, 英文名, 颜色 BGR, 级别)
#   ⚠ 英文名是给 opencv 画图用的 —— cv2.putText 只能画 ASCII，
#   直接把中文传进去渲染出来就是一串 "???"（页面上不显示中文时用 en）。
ACTION_META = {
    'fall':    ('跌倒',     'Fall',    (0, 0, 255),   LEVEL_ALARM),
    'lying':   ('倒地不起', 'Lying',   (0, 0, 255),   LEVEL_ALARM),
    'climb':   ('攀爬翻越', 'Climb',   (0, 128, 255), LEVEL_ALARM),
    'fight':   ('肢体冲突', 'Fight',   (255, 0, 255), LEVEL_ALARM),
    'intrude': ('越界闯入', 'Intrude', (0, 165, 255), LEVEL_WARN),
    'run':     ('奔跑',     'Run',     (0, 255, 255), LEVEL_WARN),
    'handup':  ('举手求救', 'Help',    (0, 255, 0),   LEVEL_WARN),
    'squat':   ('下蹲',     'Squat',   (255, 200, 0), LEVEL_INFO),
    'swing':   ('挥砍',     'Swing',   (0, 0, 220),   LEVEL_ALARM),
    'throw':   ('投掷',     'Throw',   (0, 90, 255),  LEVEL_ALARM),
    'photo':   ('拍照',     'Photo',   (200, 200, 0), LEVEL_WARN),
}


def _clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def _pt(k, i):
    """取关键点，不可用返回 None。"""
    if k is None:
        return None
    x, y, c = k[i]
    if c <= 0 or (x <= 0 and y <= 0):
        return None
    return (float(x), float(y))


def _mid(a, b):
    if a is None or b is None:
        return None
    return ((a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5)


def clip_to_box(kps, box, margin=0.35):
    """一级框约束第三级: 把离人体框太远的关节置为不可见(返回副本)。

    与 det_core 的二级约束同一个语义: 只相信"一级框附近"的关节。
    超出 `box` 宽/高 `margin` 倍以外的点一律当没看见 —— 这样远处的
    鬼点既不会画出来, 也不会参与速度/角度/越界判定。
    margin < 0 表示不限制。
    """
    if kps is None or margin is None or margin < 0:
        return kps
    x1, y1, x2, y2 = box
    mx = (x2 - x1) * margin
    my = (y2 - y1) * margin
    out = ((kps[:, 0] < x1 - mx) | (kps[:, 0] > x2 + mx) |
           (kps[:, 1] < y1 - my) | (kps[:, 1] > y2 + my))
    if not out.any():
        return kps
    k = kps.copy()
    k[out, 2] = 0.0
    return k


def _zone_px(poly, size):
    """把警戒区统一成**像素**坐标：归一化(0~1)就乘尺寸，已经是像素就原样返回。

    判据：所有坐标都 ≤ 1.5 就当成归一化（没人会用 1px 画警戒区）。

    历史 bug（2026-10-19）：配置里存的是**归一化**坐标，而越界判定用的是
    脚踝关键点的**原图像素**坐标，两边直接相比永远为 False → `intrude`
    从来没被触发过。现在在 `ActionRecognizer.update(frame_size=)` 里统一换算。
    """
    if not poly or not size:
        return poly
    try:
        if all(abs(float(x)) <= 1.5 and abs(float(y)) <= 1.5 for x, y in poly):
            w, h = size
            return [(float(x) * w, float(y) * h) for x, y in poly]
    except (TypeError, ValueError):
        pass
    return poly


class TrackState(object):
    """单个跟踪目标的历史与状态机。"""

    def __init__(self, tid, tune=None, maxlen=90, box_margin=0.35):
        self.tid = tid
        # 与 ActionRecognizer 共享同一个 dict，实现在线调灵敏度
        self.tune = tune if tune is not None else {'fall': 1.0, 'run': 1.0,
                                                   'swing': 1.0, 'throw': 1.0}
        self.box_margin = float(box_margin)   # 一级框的空间约束(同 det_core.kpt_margin)
        self.hist = deque(maxlen=maxlen)     # (t, hip, shoulder_mid, kps, box)
        self.actions = {}                    # label -> [起始ts, 分数, 最近命中ts]
        self.last_alert = 0.0
        self.foot = None

    # -------------------------------------------------- 更新
    def update(self, t, box, kps):
        # 一级框约束: 远端鬼点不进入历史, 也就不参与任何速度/角度/越界计算
        kps = clip_to_box(kps, box, self.box_margin)
        hip = _mid(_pt(kps, LH), _pt(kps, RH))
        sh = _mid(_pt(kps, LS), _pt(kps, RS))
        self.hist.append((t, hip, sh, kps, box))
        return self.analyze(t, box, kps)

    def _at(self, seconds_ago, t_now):
        """取 ~seconds_ago 之前最接近的历史样本。"""
        target = t_now - seconds_ago
        best = None
        for rec in self.hist:
            if best is None or abs(rec[0] - target) < abs(best[0] - target):
                best = rec
        return best

    # -------------------------------------------------- 主分析
    def analyze(self, t, box, kps):
        acts = {}
        x1, y1, x2, y2 = box
        bh = max(1.0, y2 - y1)                 # 人体框高（像素）—— 归一化基准

        hip = _mid(_pt(kps, LH), _pt(kps, RH))
        sh = _mid(_pt(kps, LS), _pt(kps, RS))
        lw, rw = _pt(kps, LW), _pt(kps, RW)
        lk, rk = _pt(kps, LK), _pt(kps, RK)
        la, ra = _pt(kps, LA), _pt(kps, RA)

        # ---------- 躯干倾角（与竖直方向夹角，0=直立，90=水平）
        torso_deg = None
        if hip and sh:
            dx = sh[0] - hip[0]
            dy = sh[1] - hip[1]
            if abs(dx) + abs(dy) > 1e-3:
                torso_deg = abs(math.degrees(math.atan2(dx, -dy)))

        # ---------- 髋部速度（身高/秒）
        v_norm = 0.0
        rec = self._at(0.4, t)
        if rec and rec[1] and hip:
            dt = max(1e-3, t - rec[0])
            v_norm = math.hypot(hip[0] - rec[1][0], hip[1] - rec[1][1]) / bh / dt

        # ---------- 髋高变化（相对 1.2s 前，向上为正，单位=身高）
        rise = 0.0
        rec12 = self._at(1.2, t)
        if rec12 and rec12[1] and hip:
            rise = (rec12[1][1] - hip[1]) / bh

        # ---------- 腕部速度（身高/秒）—— 同时拆出左右手与**垂直分量**
        #   左右分开：挥砍是单侧主导，而 fight 是双手都在高速乱挥；
        #   垂直分量：投掷的特征是手腕“上撩”（向上速度大）。
        wrist_v = 0.0
        wrist_v_l = wrist_v_r = 0.0
        wrist_vy = 0.0                      # 正值 = 向上
        if rec is not None:
            k0 = rec[3]
            dt = max(1e-3, t - rec[0])
            for i, side in ((LW, 'l'), (RW, 'r')):
                p1, p0 = _pt(kps, i), _pt(k0, i)
                if not (p1 and p0):
                    continue
                v = math.hypot(p1[0] - p0[0], p1[1] - p0[1]) / bh / dt
                if side == 'l':
                    wrist_v_l = v
                else:
                    wrist_v_r = v
                vy = (p0[1] - p1[1]) / bh / dt        # y 向下为正，取反=向上
                if vy > wrist_vy:
                    wrist_vy = vy
            wrist_v = max(wrist_v_l, wrist_v_r)

        hands_above_shoulder = False
        if sh and lw and rw:
            hands_above_shoulder = (lw[1] < sh[1] - 0.05 * bh) and (rw[1] < sh[1] - 0.05 * bh)
        elif sh and (lw or rw):
            w = lw or rw
            hands_above_shoulder = w[1] < sh[1] - 0.10 * bh

        feet = [p for p in (la, ra) if p]
        foot = (sum(p[0] for p in feet) / len(feet),
                sum(p[1] for p in feet) / len(feet)) if feet else None

        # ---------- 短窗口位移（给“瞬时动作”用：挥砍 / 投掷）
        #   ❗ 瞬时动作不能用 0.4s 的速度窗口：快速挥动往往是个往复，
        #   0.4s 前后位置几乎相同，净位移≈ 0，速度测出来是 0（实测踩过）。
        #   改成取 ~0.13s（≈4 帧）的位移，足以分辨一次挥动。
        rec_s = self._at(0.13, t)
        w_disp_l = w_disp_r = w_rise = 0.0
        ok_l = ok_r = False    # 左右手腕各自的 0.13s 位移是否真的拿到了
        sh_disp = 0.0      # 肩中点整体位移：剔除“人平移/整体抖动/跟踪跳变”的假位移
        arm_ext = 0.0      # 手腕到同侧肩的最大距离：手臂是否真的伸出去
        if rec_s is not None:
            k0 = rec_s[3]
            sh0 = _mid(_pt(k0, LS), _pt(k0, RS))
            if sh and sh0:
                sh_disp = math.hypot(sh[0] - sh0[0], sh[1] - sh0[1]) / bh
            for i, si, side in ((LW, LS, 'l'), (RW, RS, 'r')):
                p1, p0 = _pt(kps, i), _pt(k0, i)
                if not (p1 and p0):
                    continue
                d = math.hypot(p1[0] - p0[0], p1[1] - p0[1]) / bh
                if side == 'l':
                    w_disp_l = d
                    ok_l = True
                else:
                    w_disp_r = d
                    ok_r = True
                sp, sp0 = _pt(kps, si), _pt(k0, si)
                for q, s in ((p1, sp), (p0, sp0)):
                    if q and s:
                        arm_ext = max(
                            arm_ext, math.hypot(q[0] - s[0], q[1] - s[1]) / bh)
                r = (p0[1] - p1[1]) / bh          # 向上为正
                if r > w_rise:
                    w_rise = r

        # ================================================== 规则判定
        s_fall = _clamp(self.tune.get('fall', 1.0), 0.3, 1.0)
        s_run = max(0.3, self.tune.get('run', 1.0))
        ang_th = 75.0 - 30.0 * s_fall          # s=1 -> 45°, s=0.3 -> 66°
        v_th = 1.5 / s_run                     # s=1 -> 1.5, s=2 -> 0.75（更敏感）

        self._mark(acts, 'fall',
                   torso_deg is not None and torso_deg > ang_th and rise < -0.05,
                   t, 0.35, score=1.0 if (torso_deg or 0) > ang_th + 15 else 0.8)
        self._mark(acts, 'lying', torso_deg is not None and torso_deg > 65,
                   t, 2.5, score=0.9)
        self._mark(acts, 'climb',
                   hands_above_shoulder and (rise > 0.18 or (hip and foot and foot[1] < hip[1])),
                   t, 0.4, score=0.85)
        self._mark(acts, 'run', v_norm > v_th, t, 0.6,
                   score=min(1.0, v_norm / (v_th * 2.0)))
        self._mark(acts, 'fight', wrist_v > 5.0, t, 0.4,
                   score=min(1.0, wrist_v / 8.0))
        self._mark(acts, 'handup', hands_above_shoulder and v_norm < 0.6,
                   t, 2.0, score=0.7)
        if hip and (lk or rk):
            knee = _mid(lk, rk)
            if knee and hip[1] > knee[1] - 0.12 * bh:
                self._mark(acts, 'squat', True, t, 0.5, score=0.6)

        # ---------- 新增 3 条（2026-10-19）
        s_swing = max(0.3, self.tune.get('swing', 1.0))
        s_throw = max(0.3, self.tune.get('throw', 1.0))

        # 挥砍：**单侧**手臂在 0.13s 内大幅位移（另一侧明显小），且必须同时满足：
        #   a) 扣除肩中点整体位移后仍有 0.5 身高（≈3.8 身高/秒）
        #      —— 人平移/相机动/骨架整体跳变时肩也在动，减掉就不算了；
        #   b) 手腕离同侧肩 >= 0.3 身高（手臂真的伸出去）；
        #      走路摆臂、双手放身侧时的贴近移动达不到。
        #   c) 单侧性：另一侧 < 本侧 40%（原 50%，更强调“单侧挥”）。
        #   hold 0.2s（原 0.15）：一次挥砍是往返，能连续维持；偶发抖动/伸手不能。
        sw_l = max(0.0, w_disp_l - sh_disp)
        sw_r = max(0.0, w_disp_r - sh_disp)
        sw_max, sw_min = max(sw_l, sw_r), min(sw_l, sw_r)
        # 原始手腕位移的最大值(不扣肩位移) —— photo 用:
        #   "双手捧在眼前保持不动" 要看的是**绝对**幅度, 人整体平移时
        #   手确实也跟着动了(虽然相对肩没动), 但仍不该算"稳定拍照"。
        # ⚠ 2026-10-21: 这一行是补回来的。早先把旧版的
        #   `dmax, dmin = max(w_disp_l, w_disp_r), min(...)` 改成 sw_max/sw_min 时
        #   忘了 photo 那边还在用 dmax, 导致 NameError: name 'dmax' is not defined
        #   —— 只要人脸+双手都检测到就必崩(那一帧所有动作识别丢失),
        #   而 n_kpt 少时被 `if nose and lw and rw` 短路, 所以现场很难复现。
        dmax = max(w_disp_l, w_disp_r)
        # ⚠ 必须**两只手都有有效关键点**才能判 swing。
        #   否则“单侧性”完全是假的: 手无效时 w_disp 保持 0 → sw_min = 0 →
        #   “sw_min < sw_max * 0.4”恒为真, 只剩 sw_max 一个条件在把关。
        #   侧身站/手被身体挡住/距离远检测不全时经常只只手有效,
        #   现场表现就是“好多动作都识别成挥砸”(实测反馈)。
        # arm_ext 阈值 0.3 → 0.5: 人正常站立时手腕在身侧, 离同侧肩本来就有
        #   0.35~0.45 身高, 所以 0.3 这个条件几乎恒成立、毫无区分力;
        #   提到 0.5 才真的要求“手臂抬起来伸出去”。
        # hold 0.2 → 0.3: 一次挥砸是往返, 能连续维持; 走路摆臂/偶发抖动不行。
        self._mark(acts, 'swing',
                   ok_l and ok_r
                   and sw_max > 0.5 / s_swing and sw_min < sw_max * 0.4
                   and arm_ext > 0.5,
                   t, 0.3, score=min(1.0, sw_max / 0.85))

        # 投掷：0.13s 内手腕**上撩**超过 0.35 身高，且已经过肩。
        #   与 climb 的区别：climb 要髖部抬升/脚高于髖，投掷只要手上撩。
        self._mark(acts, 'throw',
                   w_rise > 0.35 / s_throw and hands_above_shoulder,
                   t, 0.1, score=min(1.0, w_rise / 0.6))

        # 拍照/手持设备：双手都举到**脸高附近**（鼻点 ±0.18 身高）、两手**靠得很拢**、
        #   且幅度很小保持 1.5s。
        #   与 handup 的区别：handup 是双手高举过头（手腕会高出鼻点 0.05 身高以上）；
        #   拍照是“双手捧在眼前”，手腕基本不超过鼻点太多。
        #   注意：两手距离原来是 0.40 身高（≈肩宽），太宽松，坐着双手放腿上、
        #   抱臂、叉腰都会被误识别 → 收紧到 0.22 身高（真拿手机/相机时约 0.13~0.18），
        #   并额外要求两手**纵向也对齐**（<0.15 身高），一侧抬一例垂不成立。
        nose = _pt(kps, NOSE)
        photo_hold = False
        if nose and lw and rw:
            near_face = (abs(lw[1] - nose[1]) < 0.18 * bh and
                         abs(rw[1] - nose[1]) < 0.18 * bh)
            hands_close = (abs(lw[0] - rw[0]) < 0.22 * bh and
                           abs(lw[1] - rw[1]) < 0.15 * bh)
            not_too_high = (lw[1] > nose[1] - 0.05 * bh and
                            rw[1] > nose[1] - 0.05 * bh)
            photo_hold = near_face and hands_close and not_too_high and dmax < 0.25
        self._mark(acts, 'photo', photo_hold, t, 1.5, score=0.65)

        self.foot = foot
        return acts

    def _mark(self, acts, label, cond, t, hold, score=1.0):
        """条件持续 hold 秒后才产生动作；条件消失 0.6s 后清除状态。"""
        if cond:
            st = self.actions.get(label)
            if st is None:
                self.actions[label] = [t, score, t]
                return
            st[1] = max(st[1] * 0.7, score)
            st[2] = t
            if t - st[0] >= hold:
                acts[label] = (st[1], t - st[0])
        else:
            st = self.actions.get(label)
            if st is not None and t - st[2] > 0.6:
                self.actions.pop(label, None)

    def mark_intrude(self, t, polygon, acts):
        """越界判定：脚点落入警戒多边形。"""
        if not polygon or self.foot is None:
            return
        if self._point_in_poly(self.foot, polygon):
            self._mark(acts, 'intrude', True, t, 0.3, score=0.9)
        else:
            self._mark(acts, 'intrude', False, t, 0.3)

    @staticmethod
    def _point_in_poly(pt, poly):
        x, y = pt
        inside = False
        n = len(poly)
        for i in range(n):
            x1, y1 = poly[i]
            x2, y2 = poly[(i + 1) % n]
            if (y1 > y) != (y2 > y):
                xint = (x2 - x1) * (y - y1) / (y2 - y1 + 1e-9) + x1
                if x < xint:
                    inside = not inside
        return inside


class ActionRecognizer(object):
    """管理所有 track 的状态机，给每个结果附加 actions / risk。"""

    def __init__(self, alert_polygon=None, cooldown=2.0, box_margin=0.35):
        self.tracks = {}
        self.alert_polygon = alert_polygon or []
        self.cooldown = cooldown
        self.events = deque(maxlen=100)       # 事件日志
        # 一级框对三级动作判定的空间约束(同 det_core.kpt_margin)
        self.box_margin = float(box_margin)
        # 可在线调节的灵敏度（1.0 为默认；越大越容易触发）
        self.tune = {'fall': 1.0, 'run': 1.0, 'swing': 1.0, 'throw': 1.0}

    def update(self, t, results, frame_size=None):
        """results: [ {tid, box, score, kps}, ... ]；原样返回并附加 actions。

        frame_size=(宽, 高)：用于把**归一化**的警戒多边形换算成像素。
        “越界”的判定用的是脚踝关键点（原图像素），而配置里存的是归一化坐标，
        两边直接比永远不成立 —— 历史 bug，2026-10-19 修。
        """
        alive = set()
        for r in results:
            tid = r.get('tid', -1)
            alive.add(tid)
            st = self.tracks.get(tid)
            if st is None:
                st = self.tracks[tid] = TrackState(tid, self.tune,
                                                   box_margin=self.box_margin)
            acts = st.update(t, r['box'], r.get('kps'))
            if self.alert_polygon:
                st.mark_intrude(t, _zone_px(self.alert_polygon, frame_size), acts)

            labels = []
            for label, (score, dur) in acts.items():
                cn, en, color, level = ACTION_META[label]
                labels.append({'label': label, 'cn': cn, 'en': en, 'color': color,
                               'level': level, 'score': float(score), 'dur': float(dur)})
                if level >= LEVEL_ALARM and t - st.last_alert > self.cooldown:
                    st.last_alert = t
                    self.events.append({'t': t, 'tid': tid, 'label': label,
                                        'cn': cn, 'en': en, 'score': float(score)})
            labels.sort(key=lambda a: (-a['level'], -a['score']))
            r['actions'] = labels
            r['risk'] = max([a['level'] for a in labels], default=0)

        for tid in list(self.tracks.keys()):
            if tid not in alive:
                self.tracks.pop(tid, None)
        return results
