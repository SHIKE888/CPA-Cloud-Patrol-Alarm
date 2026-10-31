# -*- coding: utf-8 -*-
"""动作分类器 —— `rk/web/action_demo.html` 里 `demoClassifier()` 的 **Python 逐行移植**。

为什么不用训练出来的 ST-GCN
--------------------------
训练链路本身是通的（`action_net.npz` 与 Keras 差 1e-5、浏览器 JS 前向差 6e-7），
但**公开数据源不够干净**：唯一能提供 idle/run/handup 的是 JHMDB(DD-Net 版)，
而它的 `joint_positions.mat` 关节顺序是乱的 —— 实测骨骼长度帧间变异系数 ≈0.13
（真骨骼应 <0.02），`idle` 类 99.8% 的样本"鼻子在髋下方 0.8 个身高"。
用这种数据训出来的模型，遇到干净的站立骨架会一律判成 climb（实测 p=0.999）。

演示页里的这套显式打分**不依赖数据**：每个类都是"人写的充分条件"，参数是照着
前级（YOLO-pose + EMA α≈0.55）**实际可达**的数值标定的，所以在板上一次就对。
以后采到干净的 idle/run/handup，再回头上模型。

输出与 `ActionModel` 完全同构，所以 `ActionEngine`（滞回、越界、告警）一行不用改：
    classes / backend / ok / err / infer_ms / predict(seq) / release()
"""
import time

import numpy as np

# 必须与 action_model.DEFAULT_CLASSES 顺序一致（接口契约）
CLASSES = ['idle', 'fall', 'climb', 'fight', 'run',
           'handup', 'squat', 'swing', 'throw', 'photo']

NOS = 0
LSH, RSH = 5, 6
LW, RW = 9, 10
LH, RH = 11, 12
LA, RA = 15, 16

# 演示页里 dt 固定 1/30、窗口 32 帧 → 实际跨度 31/30 ≈ 1.033 s。
# 板上必须用同一个跨度，否则速度（身高/秒）整体缩放，阈值全错位。
DEMO_WINDOW = 31.0 / 30.0

SOFT_TEMP = 0.16          # 温度 softmax：让 top1 拉开

# 骨架可信度门控：窗口内"解剖学自洽的帧"少于这个比例，就一律判 idle
GOOD_MIN = 0.5
IDLE_ON_BAD = 0.90

# 挥臂角幅度门限(度)：高于它才算"一次挥击"。
# 参考值：挥砍 100~160°、投掷 90~140°、走路摆臂 30~60°、抬手挠头 60~90°。
# 这个数是用真实片段标的（capture_board.py 录 / eval_board_clips.py 评），
# 先取 70° 作为保守值：宁可漏一些小幅度挥击，也不要满屏误报。
SWEEP_DEG = 70.0

NAN = float('nan')


def _mean(x):
    """对有效子集求均值；空集返回 NaN（而不是 0，0 会被当成真实测量值）。"""
    x = np.asarray(x, np.float64)
    return float(x.mean()) if x.size else NAN


def _miss(*vals):
    """任一项缺失(NaN/None) → True。

    用来实现"**看不见就不判**"：人被画面切掉一半时，缺的那个量不能当成 0
    或当成"静止"，否则会得出"腿长为 0 → 在下蹲"之类的荒谬结论。
    """
    for v in vals:
        if v is None:
            return True
        try:
            if np.isnan(float(v)):
                return True
        except (TypeError, ValueError):
            return True
    return False


def soft(v, c, w):
    """软阶跃 1/(1+e^-((v-c)/w))。w 越小越"硬"。"""
    return 1.0 / (1.0 + np.exp(-(v - c) / w))


def features(seq, dt=1.0 / 30.0):
    """从 (T,17,3) 归一化序列提特征。语义与 JS 版 `features()` 完全一致。

    seq 的 x,y = (像素 - 髋中心) / 人体框高，第 3 维 = 有效标志。
    所有速度单位是 **身高/秒**。
    """
    a = np.asarray(seq, np.float32)
    T = a.shape[0]
    valid = a[:, :, 2] > 0
    xy = a[:, :, :2]

    def spd(i):
        """某关节的峰值速度（只算两帧都有效的相邻对）。"""
        ok = valid[1:, i] & valid[:-1, i]
        if not ok.any():
            return 0.0
        d = np.linalg.norm(xy[1:, i] - xy[:-1, i], axis=1)
        return float(d[ok].max() / dt)

    def midv(i, j):
        """逐帧中点 (T,2) + 逐帧有效 (T,)。"""
        ok = valid[:, i] & valid[:, j]
        return (xy[:, i] + xy[:, j]) * 0.5, ok

    def peak(m, ok):
        if T < 2:
            return 0.0
        o = ok[1:] & ok[:-1]
        if not o.any():
            return 0.0
        d = np.linalg.norm(m[1:] - m[:-1], axis=1)
        return float(d[o].max() / dt)

    sh, sh_ok = midv(LSH, RSH)          # 肩中点
    hp, hp_ok = midv(LH, RH)            # 髋中点
    an, an_ok = midv(LA, RA)            # 踝中点
    shV = peak(sh, sh_ok)
    hipV = peak(hp, hp_ok)

    wrL, wrR = spd(LW), spd(RW)

    # ---- 末段 8 帧的几何量（逐帧算，只用该帧所需关节都有效的帧）
    s8 = slice(max(0, T - 8), T)
    vwl, vwr = valid[s8, LW], valid[s8, RW]
    both_w = vwl & vwr
    lwx, lwy = xy[s8, LW, 0], xy[s8, LW, 1]
    rwx, rwy = xy[s8, RW, 0], xy[s8, RW, 1]
    dHandsH = _mean(np.abs(lwx - rwx)[both_w])
    dHandsV = _mean(np.abs(lwy - rwy)[both_w])
    wY = _mean(((lwy + rwy) * 0.5)[both_w])
    vh = valid[s8, LH] & valid[s8, RH]
    hoY = _mean(((xy[s8, LH, 1] + xy[s8, RH, 1]) * 0.5)[vh])
    vn = valid[s8, NOS]
    noseY = _mean(xy[s8, NOS, 1][vn])
    handAboveHip = _mean((((xy[s8, LH, 1] + xy[s8, RH, 1]) * 0.5)
                          - ((lwy + rwy) * 0.5))[vh & both_w])

    # 手到鼻的最小距离（拍照需要"手在脸前"）
    dn = []
    for wx, wy, vw in ((lwx, lwy, vwl), (rwx, rwy, vwr)):
        ok = vn & vw
        if ok.any():
            dn.append(np.hypot(wx - xy[s8, NOS, 0], wy - xy[s8, NOS, 1])[ok])
    dNose = float(min(float(d.min()) for d in dn)) if dn else NAN

    # 躯干角（相对竖直，度）：取最后一帧"肩+髋"都有效的
    torso = NAN
    okb = sh_ok & hp_ok
    if okb.any():
        tv = sh[okb][-1] - hp[okb][-1]
        torso = float(abs(np.arctan2(tv[0], -tv[1])) * 180.0 / np.pi)

    hipRise = float(hp[okb][0, 1] - hp[okb][-1, 1]) if okb.sum() >= 2 else NAN

    # 踝/髋相关的量：髋+双脚都看得见才能算
    def leg_pair(nlast):
        s = slice(max(0, T - nlast), T)
        ok = (valid[s, LH] & valid[s, RH] & valid[s, LA] & valid[s, RA])
        h = (xy[s, LH, 1] + xy[s, RH, 1]) * 0.5
        a_ = (xy[s, LA, 1] + xy[s, RA, 1]) * 0.5
        return h, a_, ok

    h5, a5, ok5 = leg_pair(5)
    ankleUp = _mean((h5 - a5)[ok5])
    ankleV = max(spd(LA), spd(RA))
    h6, a6, ok6 = leg_pair(6)
    legLen = _mean((a6 - h6)[ok6])
    legLen0 = float(a6[0] - h6[0]) if (ok6.size and ok6[0]) else NAN

    # ---- 挥臂角幅度：肩→腕 方向在窗口内扫过的最大夹角(度)
    # 这是"挥击 vs 日常手臂动作"的关键维度，也是原来**最缺**的那个：
    #   挥砍/投掷是一次大幅弧线（肩→腕方向扫 100°+），
    #   走路摆臂 / 抬手挠头 / 拿东西 / 看手机 只有 30~60°。
    # 少了它，"手在快速动"就直接等于挥砍 —— 所以以前误报全是 swing。
    def sweep(sh_idx, wr_idx):
        sv = valid[:, sh_idx] & valid[:, wr_idx]
        if sv.sum() < 3:
            return NAN
        dx = xy[sv, wr_idx, 0] - xy[sv, sh_idx, 0]
        dy = xy[sv, wr_idx, 1] - xy[sv, sh_idx, 1]
        n = np.hypot(dx, dy)
        keep = n > 1e-6
        if keep.sum() < 3:
            return NAN
        ux, uy = dx[keep] / n[keep], dy[keep] / n[keep]
        # 方向两两夹角的最大值：不用解 unwrap，也不会被 ±180° 绕回坑到
        dot = np.clip(ux[:, None] * ux[None, :] + uy[:, None] * uy[None, :], -1, 1)
        return float(np.degrees(np.arccos(dot.min())))

    sw_l, sw_r = sweep(LSH, LW), sweep(RSH, RW)
    arm_sweep = NAN
    if not (np.isnan(sw_l) and np.isnan(sw_r)):
        arm_sweep = float(np.nanmax([sw_l, sw_r]))

    # ---------------------------------------------------------------- 骨架可信度
    # 为什么要这一道：镜头只拍到头部/肩膀时，姿态模型会"硬解"出一付乱骨架
    # （实测 17 个点全部有值，但平均置信度 0.31、最低 0.00），解出来的
    # 踝部跑到髖上方（legLen = −0.17）→ squat 直接 1.0、ankleV 2.6 → run。
    # 用户看到的就是"误报全是某一个动作，其他动作都识别不到"。
    #
    # 判据只用**解剖学硬约束**，不要求"站着"（否则跌倒/躺卧会被误杀）：
    #   * 有效关节数 >= 9（17 点里至少看过一斗）
    #   * 踝不能在髖上方超过 0.10（躺卧时 ≈0，乱骨架会是一 0.2 以上）
    #   * 鼻不能在髖下方超过 0.55（躺卧时 ≈0）
    cnt = valid.sum(1)
    legs_vis = valid[:, LA] & valid[:, RA] & valid[:, LH] & valid[:, RH]
    legf = (xy[:, LA, 1] + xy[:, RA, 1]) * 0.5 - (xy[:, LH, 1] + xy[:, RH, 1]) * 0.5
    hipy = (xy[:, LH, 1] + xy[:, RH, 1]) * 0.5
    ok_frame = (cnt >= 9) & ~(legs_vis & (legf < -0.10))
    nose_vis = valid[:, NOS] & valid[:, LH] & valid[:, RH]
    if nose_vis.any():
        ok_frame &= ~(nose_vis & (xy[:, NOS, 1] > hipy + 0.55))
    good = float(ok_frame.mean()) if T else 0.0

    return dict(wrL=wrL, wrR=wrR,
                wrMax=max(wrL, wrR), wrMin=min(wrL, wrR),
                shV=shV, hipV=hipV, dHandsH=dHandsH, dHandsV=dHandsV,
                wY=wY, hoY=hoY, noseY=noseY, handAboveHip=handAboveHip,
                dNose=dNose, torso=torso, hipRise=hipRise, ankleUp=ankleUp,
                ankleV=ankleV, legLen=legLen, legLen0=legLen0,
                arm_sweep=arm_sweep, good=good)


def classify(f, sens=None):
    """特征 → 10 类概率。逐行对应 `demoClassifier()`。

    sens: 可选灵敏度系数 {fall,run,swing,throw}，默认全 1.0。
         网页上原有的 4 个"灵敏度"滑杆就是这四个键 —— 保特同一份契约，
         不然后端换掉之后那几个滑杆会变成空操作（看起来在的，但没效果）。
         裁剪范围也和旧几何规则一致：fall 限 0.3~1.0，其余下限 0.3。
    """
    sens = sens or {}

    def _k(name, lo=0.3, hi=99.0):
        return min(hi, max(lo, float(sens.get(name, 1.0))))

    # ---- 骨架可信度门控 ---------------------------------------------------
    # 姿态模型在"只拍到局部 / 遮挡严重"时会给出一付**乱骨架**，它的特征值
    # 完全无意义（实测 legLen=-0.17、ankleV=2.6），却恰好能踩中 squat/run/swing
    # 的阈值——这就是"误报全是某一个动作"的来源。这种情况一律判 idle，
    # 宁可漏报也不乱报（告警类系统里误报的代价更高）。
    if f.get('good', 1.0) < GOOD_MIN:
        p = np.full(len(CLASSES), (1.0 - IDLE_ON_BAD) / (len(CLASSES) - 1),
                    np.float32)
        p[CLASSES.index('idle')] = IDLE_ON_BAD
        return p

    s = {}

    # 扣掉肩中点平移后的左右腕峰值速度（身高/秒）
    l = f['wrL'] - min(f['shV'], 1.2)
    r = f['wrR'] - min(f['shV'], 1.2)
    mx, mn2 = max(l, r), min(l, r)
    single = min(1.0, max(0.0, 1.0 - mn2 / mx)) if mx > 0.1 else 0.0
    high = f['noseY'] - f['wY']                 # 正 = 手比鼻子高

    # 挥砍：单侧快速 + 手没有垂在髋下
    #   阈值按**前级实际可达**的峰值速度标定（EMA α=0.55 后约 1~2 身高/秒），
    #   不是理想姿态的 4~9 —— 旧几何规则用 4.0 就永远不触发。
    # 挥砍：单侧快速 + 手没有垂在髋下 + **必须是一次大幅弧线**
    #   阈值按**前级实际可达**的峰值速度标定（EMA α=0.55 后约 1~2 身高/秒），
    #   不是理想姿态的 4~9 —— 旧几何规则用 4.0 就永远不触发。
    #   参考角度：挥砍 100~160°，投掷 90~140°，走路摆臂 30~60°，抬手挠头 60~90°。
    s['swing'] = 0.0 if _miss(f['handAboveHip'], f['arm_sweep']) else (
        soft(mx, 1.00, 0.20) * (0.35 + 0.65 * single)
        * (1.0 if f['handAboveHip'] > -0.12 else 0.35)
        * soft(f['arm_sweep'], SWEEP_DEG, 12.0) * _k('swing'))

    # 投掷：快速上撩 + 手已过肩 + 仍是单侧主导
    s['throw'] = 0.0 if _miss(f['handAboveHip'], f['arm_sweep']) else (
        soft(mx, 1.00, 0.20) * soft(f['handAboveHip'], 0.10, 0.05)
        * soft(f['arm_sweep'], SWEEP_DEG - 15, 12.0)
        * (0.4 + 0.6 * single) * 0.95 * _k('throw'))

    # 肢体冲突：双手都在快速动 + 手在胸前（跟奔跑摆臂区分）
    s['fight'] = 0.0 if _miss(f['handAboveHip']) else (
        soft(mn2, 0.70, 0.18) * soft(f['handAboveHip'], 0.15, 0.06) * 0.9)

    # 拍照：手在脸前 + 两手靠拢且同高 + 幅度很小
    s['photo'] = 0.0 if _miss(f['dNose'], f['dHandsH'], f['dHandsV']) else (
        soft(-f['dNose'], -0.14, 0.05) * soft(-f['dHandsH'], -0.20, 0.06)
        * soft(-f['dHandsV'], -0.14, 0.05)
        * (1.0 if mx < 1.6 else 0.15))

    # 举手：手高于鼻子（比拍照更高）+ 腿基本不动（跟攀爬区分）
    s['handup'] = 0.0 if _miss(f['handAboveHip'], high) else (
        soft(f['handAboveHip'], 0.40, 0.05) * soft(high, 0.03, 0.03)
        * (0.25 + 0.75 * soft(-f['ankleV'], -0.6, 0.25))
        * (1.0 if mx < 1.4 else 0.4) * 0.95)

    # 奔跑：踝部快节奏 + 双手都在动
    s['run'] = soft(f['ankleV'], 0.90, 0.20) * soft(mn2, 0.55, 0.18) * 0.95 * _k('run')

    # 下蹲：腿长（踝-髋）明显变短。站着 ≈0.46，蹲下 ≈0.35。
    #   ❗ 用**绝对**腿长而不是"窗口首帧 vs 当前"的差值：动作是周期性的，
    #   窗口首帧恰好落在蹲底时差值会变负 → 直接漏报。
    s['squat'] = 0.0 if _miss(f['legLen'], f['torso']) else (
        soft(-f['legLen'], -0.40, 0.025)
        * (1.0 if f['torso'] < 25 else 0.1) * 0.9)

    # 倒地/跌倒（已合并成一类）：躯干角 42° 以上就算
    s['fall'] = 0.0 if _miss(f['torso']) else (
        soft(f['torso'], 42.0, 5.0) * 0.95 * _k('fall', 0.3, 1.0))

    # 攀爬：手很高 + 双腿在动
    s['climb'] = 0.0 if _miss(f['handAboveHip']) else (
        soft(f['handAboveHip'], 0.40, 0.05) * soft(f['ankleV'], 0.7, 0.25) * 0.95)

    # idle：所有"动作证据"都弱时才高
    ev = max(s['swing'], s['throw'], s['fight'], s['photo'], s['handup'],
             s['run'], s['squat'], s['fall'], s['climb'])
    s['idle'] = min(1.0, max(0.0, 0.72 * (1.0 - ev) + 0.08))
    v = np.array([max(0.0, s.get(k, 0.0)) for k in CLASSES], np.float64)
    ex = np.exp((v - v.max()) / SOFT_TEMP)
    return (ex / ex.sum()).astype(np.float32)


class DemoActionModel(object):
    """`ActionModel` 的同构替身：`ActionEngine` 不需要知道背后是模型还是规则。

    参数
    ----
    t_len  : 输入序列长度（默认 32，与 SeqBuffer 一致）
    window : 序列时长（秒）。None = 用演示页标定的 31/30 ≈ 1.033 s。
             给错会让所有速度阈值整体缩放，务必和 ActionEngine 的 window 一致。
    """

    def __init__(self, t_len=32, window=None, classes=None):
        self.name = 'demo-cls'
        self.backend = 'demo'
        self.ok = True
        self.err = ''
        self.classes = list(classes or CLASSES)
        self.t_len = int(t_len)
        self.window = float(window) if window else DEMO_WINDOW
        self.dt = self.window / max(1, self.t_len - 1)
        self.infer_ms = 0.0
        self.last_features = None          # 供 /api/ai 调试查看
        # 网页"灵敏度"滑杆直接写这个 dict（ActionEngine.tune 与它共享同一份）
        self.tune = {'fall': 1.0, 'run': 1.0, 'swing': 1.0, 'throw': 1.0}

    def predict(self, seq):
        t0 = time.time()
        f = features(seq, self.dt)
        p = classify(f, self.tune)
        self.last_features = f
        self.infer_ms = (time.time() - t0) * 1000.0
        return p

    def release(self):
        pass
