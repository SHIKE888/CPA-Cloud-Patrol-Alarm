# -*- coding: utf-8 -*-
"""云台追踪环路离线仿真：对比"旧控制律"和"新控制律（环路整形）"会不会摆。

模型（按现场实测标定的量级）：
  * 相机水平视场 67°（IMX415+4.2mm），归一化误差 e = 2*Δθ/67 ≈ 0.0299 / 度
  * AI 推理 4~8 fps，结果到达时已经过时 age≈0.12 s（用延迟队列模拟）
  * 云台 45°/s 上限，加速度斜坡 450°/s²，控制周期 25 ms
  * 目标：站着不动（最容易暴露极限环）；另外再测一次 0.5 m/s 横穿

旧律：aim 点 k=0.5 低通 + 卡尔曼 pos_at(ahead) + 死区 0.015 + 满速到 0.35
新律：aim 点 τ=120ms + 每拍位移限幅 + vel/pred 限幅 + 小误差降速 + 死区滞回

两只都喂同一串"aim 点抖动"（模拟 头部/几何中心/框中心 在临界处来回切）。
"""
import math
import sys

FOV = 67.0
KPLANT = 2.0 / FOV          # 归一化误差 / 度
VMAX = 45.0
ACCEL = 450.0
PERIOD = 0.025
AI_FPS = 4.0                # 实测 det 4fps（双月 + 编码占 CPU）
AGE = 0.40                  # 实测总延迟：age 0.12 + 流水线/串口 ≈ 0.4s
KP_NEW = 40.0               # 新律比例增益 (°/s)/归一化


class KF:
    """和 gimbal_web._KalmanCV 同构的一维匀速卡尔曼。"""

    def __init__(self, r=5e-4, q=0.8):
        self.r, self.q = r, q
        self.x = 0.0
        self.v = 0.0
        self.p00 = 1.0
        self.p01 = 0.0
        self.p11 = 1.0

    def reset(self, x):
        self.x, self.v = x, 0.0
        self.p00, self.p01, self.p11 = 1.0, 0.0, 1.0

    def predict(self, dt):
        self.x += self.v * dt
        self.p00 += dt * (2 * self.p01 + dt * self.p11) + self.q * dt
        self.p01 += dt * self.p11
        self.p11 += self.q * dt

    def update(self, z, dt):
        self.predict(dt)
        s = self.p00 + self.r
        k0, k1 = self.p00 / s, self.p01 / s
        y = z - self.x
        self.x += k0 * y
        self.v += k1 * y
        self.p00 -= k0 * self.p00
        self.p01 -= k0 * self.p01
        self.p11 -= k1 * self.p01
        return self.x, self.v

    def pos_at(self, t):
        return self.x + self.v * t


class Ctrl:
    def __init__(self, new=True):
        self.new = new
        self.kf = KF()
        self.aim = None
        self.moving = False
        self.v = 0.0

    def step(self, meas, dt, ahead, moving_jitter):
        """meas: 本拍拿到的（已过时的）归一化误差；None = 本拍没有新结果。"""
        if meas is not None:
            if self.aim is None:
                self.aim = meas
            elif self.new:
                k = min(0.5, max(0.05, PERIOD / (0.12 + PERIOD)))
                d = (meas - self.aim) * k
                d = max(-0.06, min(0.06, d))
                self.aim += d
            else:
                self.aim += (meas - self.aim) * 0.5
            x, v = self.kf.update(self.aim, 1.0 / AI_FPS)
            if self.new:
                v = max(-1.5, min(1.5, v))
                p = x + max(-0.25, min(0.25, v * ahead))
            else:
                p = self.kf.pos_at(ahead)
        else:
            self.kf.predict(PERIOD)
            x = self.kf.x
            p = self.kf.pos_at(ahead) if not self.new else \
                x + max(-0.25, min(0.25, max(-1.5, min(1.5, self.kf.v)) * ahead))
        err = p
        dead = 0.015
        if self.new:
            thr = dead if self.moving else dead * 2.4
            if abs(err) <= thr:
                self.moving = False
                want = 0.0
            else:
                self.moving = True
                v = min(VMAX, KP_NEW * (abs(err) - dead))
                if abs(err) < 0.12:
                    v = min(v, VMAX * (abs(err) / 0.12) * 0.18 * 3.0)
                want = -v * (1 if err > 0 else -1)
        else:
            if abs(err) <= dead:
                want = 0.0
            else:
                mag = min(1.0, (abs(err) - dead) / 0.335)
                want = -mag * VMAX * (1 if err > 0 else -1)
        # 加速度斜坡
        dv = ACCEL * dt
        self.v += max(-dv, min(dv, want - self.v))
        return self.v


def run(new, target_fn, dur=14.0, jitter=True):
    t = 0.0
    theta = 0.0                 # 云台角
    ctrl = Ctrl(new)
    hist = []
    # 测量延迟队列：AI 每 1/AI_FPS 出一个结果，结果里含"当时"的误差
    next_ai = 0.0
    pending = []                # (到达时刻, 误差)
    k = 0
    while t < dur:
        # 目标位置
        tgt = target_fn(t)
        # AI 出结果（带 aim 抖动）
        if t >= next_ai:
            raw = (theta - tgt) * KPLANT
            if jitter:
                # 头部/几何中心/框中心 切换：实测每 0.3~0.7s 就跳一次，
                # 人离得近（0.6~2m）时三种瞄准点差 0.3~0.6 归一化，非常大。
                k += 1
                if k % max(1, int(round(0.5 * AI_FPS))) == 0:
                    raw += 0.45 if (k // 3) % 2 == 0 else -0.30
            pending.append((t + AGE, raw))
            next_ai = t + 1.0 / AI_FPS
        meas = None
        while pending and pending[0][0] <= t:
            meas = pending.pop(0)[1]
        ahead = 0.10 + AGE
        ctrl.step(meas, PERIOD, ahead, jitter)
        theta += ctrl.v * PERIOD
        hist.append((t, theta, ctrl.v, (theta - tgt) * KPLANT))
        t += PERIOD
    tail = [h for h in hist if h[0] > 4.0]
    pp = max(h[1] for h in tail) - min(h[1] for h in tail)
    err_pp = max(h[3] for h in tail) - min(h[3] for h in tail)
    vabs = max(abs(h[2]) for h in tail)
    return pp, err_pp, vabs, hist


def main():
    stand = lambda t: 6.0                     # 站着不动，偏 6°
    walk = lambda t: 6.0 + 3.0 * math.sin(2 * math.pi * t / 6.0)   # 缓慢横扫
    ok = True
    for name, fn in (("站立不动 6°", stand), ("缓慢横扫 ±3°", walk)):
        for new in (False, True):
            pp, epp, vabs, _ = run(new, fn)
            tag = "新律" if new else "旧律"
            print("%-14s %s: yaw 摆幅 %6.2f°  误差摆幅 %5.2f  峰值速度 %5.1f°/s"
                  % (name, tag, pp, epp, vabs))
        _, _, _, h_old = run(False, fn)
        _, _, _, h_new = run(True, fn)
        pp_old = max(x[1] for x in h_old if x[0] > 4) - min(x[1] for x in h_old if x[0] > 4)
        pp_new = max(x[1] for x in h_new if x[0] > 4) - min(x[1] for x in h_new if x[0] > 4)
        if pp_new >= pp_old:
            ok = False
            print("  ✗ 新律没有改善")
        else:
            print("  ✓ 摆动缩小到 %.0f%%" % (100.0 * pp_new / max(1e-6, pp_old)))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
