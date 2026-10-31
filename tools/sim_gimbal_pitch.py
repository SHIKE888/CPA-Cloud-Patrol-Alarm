# -*- coding: utf-8 -*-
"""云台**俯仰(pitch)**环路离线仿真：为什么"瞄准后周期上下摆动"。

和 sim_gimbal_track.py（yaw）同一套模型，只换成俯仰轴 + 俯仰特有的激励。

俯仰视角 45°（IMX415 + 4.2mm，垂直方向）→ 归一化误差 e = 2*dTheta/45。

实测现象（用户）："云台瞄准后还是会周期上下摆动，导致乱飘"。
俯仰摆动的燃料不是"增益大"，而是 **aim 点在垂直方向的跳变**：
  ai_overlay 的 aim 在「头部 / 人体几何中心 / 框中心」之间切换，三者 y 相差
  人体高度的 0.2~0.4；人越近框越高，跳变越大（归一化 0.5~0.6 量级）。
  这个阶跃 + 0.45s 视觉延迟 + 前瞻放大 = 1~2Hz 极限环。

对比三种控制律：
  old  : 前瞻 + 死区 0.015 + 全比例增益（= 现在线上的 pitch 路径）
  hold : 无前瞻 + 死区 0.10 + 半增益 + 限速 10度/s（本次要上的默认）
  hold2: 更保守 —— 死区 0.15 + 四分之一增益（备用）

输出用纯 ASCII（Windows 控制台是 GBK，打对勾会 UnicodeEncodeError）。
"""
import random

FOV_V = 45.0
KPL = 2.0 / FOV_V          # 归一化误差 / 度
VMAX = 15.0                # 俯仰限速（gimbal_web 里 min(speed_max,15)）
ACCEL = 450.0
PERIOD = 0.025
AI_FPS = 4.0               # 实测 det 4fps（双目 + 编码占 CPU）
AGE = 0.45                 # age_ms 0.12 + 流水线/串口
KP = 40.0
DEAD = 0.015


class KF(object):
    """一维匀速卡尔曼（和 gimbal_web._KalmanCV 同构）。"""

    def __init__(self, r=5e-4, q=0.8):
        self.r, self.q = r, q
        self.x = 0.0
        self.v = 0.0
        self.p00 = 1.0
        self.p01 = 0.0
        self.p11 = 1.0

    def update(self, z, dt):
        self.x += self.v * dt
        self.p00 += self.p01 * dt
        self.p01 += self.p11 * dt
        self.p11 += self.q * dt
        y = z - self.x
        s = self.p00 + self.r
        k0, k1 = self.p01 / s, self.p11 / s
        self.x += k0 * y
        self.v += k1 * y
        self.p00 -= k0 * self.p01
        self.p01 -= k0 * self.p11
        self.p11 -= k1 * self.p11
        return self.x, self.v


class Ctrl(object):
    def __init__(self, mode):
        self.mode = mode
        self.kf = KF()
        self.v = 0.0
        self.aim_s = None
        self.active = False
        self.moving = False

    def step(self, meas, dt, ahead):
        if meas is None:
            # 没有新结果：只做加速度斜坡回到 0（线上还会做 kf.predict）
            self.v += max(-ACCEL * dt, min(ACCEL * dt, 0.0 - self.v))
            return self.v
        # aim 低通（tau=120ms）+ 每拍位移限幅 0.06 归一化（和线上一致）
        if self.aim_s is None:
            self.aim_s = meas
        else:
            k = min(0.5, max(0.05, PERIOD / (0.12 + PERIOD)))
            d = (meas - self.aim_s) * k
            d = max(-0.06, min(0.06, d))
            self.aim_s += d
        e = self.aim_s
        if self.mode == "old":
            xs, vel = self.kf.update(e, dt)
            vel = max(-1.5, min(1.5, vel))
            p = xs + max(-0.25, min(0.25, vel * ahead))
            dead = DEAD
            if abs(p) <= (dead if self.moving else dead * 2.4):
                self.moving = False
                want = 0.0
            else:
                self.moving = True
                mag = min(VMAX, KP * (abs(p) - dead))
                want = -mag * (1 if p > 0 else -1)
        else:
            self.kf.update(e, dt)
            dead = 0.05 if self.mode == "hold" else 0.15
            gain = 0.7 if self.mode == "hold" else 0.25
            vmax = 10.0 if self.mode == "hold" else 8.0
            a = abs(e)
            if self.active:
                if a <= dead:
                    self.active = False
            elif a >= dead * 1.5:
                self.active = True
            if self.active:
                mag = min(vmax, KP * gain * (a - dead))
                want = -mag * (1 if e > 0 else -1)
            else:
                want = 0.0
        dv = ACCEL * dt
        self.v += max(-dv, min(dv, want - self.v))
        return self.v


def run(mode, jump, noise=0.05, dur=18.0, seed=7):
    """jump = aim 点垂直跳变幅度（归一化）。近 0.60 / 中 0.35 / 远 0.15。"""
    rnd = random.Random(seed)
    theta = 0.0
    ctrl = Ctrl(mode)
    hist = []
    next_ai = 0.0
    pend = []
    k = 0
    t = 0.0
    while t < dur:
        if t >= next_ai:
            raw = theta * KPL                      # 目标就在正前方
            raw += rnd.gauss(0.0, noise)           # 框/关键点抖动
            k += 1
            # 每 0.55s 切一次瞄准点，方向交替（头部 <-> 几何中心）
            if k % max(1, int(round(0.55 * AI_FPS))) == 0:
                raw += jump if (k // 3) % 2 == 0 else -jump * 0.66
            pend.append((t + AGE, raw))
            next_ai = t + 1.0 / AI_FPS
        meas = None
        while pend and pend[0][0] <= t:
            meas = pend.pop(0)[1]
        ctrl.step(meas, PERIOD, 0.10 + AGE)
        theta += ctrl.v * PERIOD
        hist.append((t, theta, ctrl.v))
        t += PERIOD
    tail = [h for h in hist if h[0] > 7.0]
    pp = max(h[1] for h in tail) - min(h[1] for h in tail)
    vpk = max(abs(h[2]) for h in tail)
    return pp, vpk


def main():
    ok = True
    # jump=0.0 = aim 单点化之后的情形（只余框/关键点抖动）
    for label, jump in (("single-point (aim jump 0.00)", 0.0),
                        ("near  (aim jump 0.60)", 0.60),
                        ("mid   (aim jump 0.35)", 0.35),
                        ("far   (aim jump 0.15)", 0.15)):
        print("\n%s -- pitch swing / peak speed" % label)
        res = {}
        for mode in ("old", "hold", "hold2"):
            pp, vpk = run(mode, jump)
            res[mode] = pp
            print("  %-6s swing %6.2f deg   peak %5.1f deg/s" % (mode, pp, vpk))
        if res["old"] < 0.3:
            print("  [OK] old 本身已经不摆（aim 单点化的功劳）")
        elif res["hold"] >= res["old"] - 1e-6:
            ok = False
            print("  [X] hold 没有改善")
        else:
            print("  [OK] hold 把摆幅压到 old 的 %.0f%%"
                  % (100.0 * res["hold"] / max(1e-6, res["old"])))
    print("\nPASS" if ok else "\nFAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
