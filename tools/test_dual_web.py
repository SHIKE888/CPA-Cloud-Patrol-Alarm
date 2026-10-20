# -*- coding: utf-8 -*-
"""本地验证双目拼接逻辑 (不需要板子 / 不需要 FPGA)。

测三件事:
  1. _peek_dual_src 能不能从 NV16 原始缓冲头 4 字节认出 cam0 / cam1 / 无标记
  2. _dual_compose 的配对、30fps 节流、去重、单路降级行为
  3. _target_size 在双目模式是否取半宽

跑法: python tools/test_dual_web.py
"""
import sys
import os
import types
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "rk", "web"))

import numpy as np
import mipi_webstream as M

# 开发机(Windows)上没装 cv2, 而 mipi_webstream 在 cv2 缺失时会把 np 也置 None。
# 被测的两个方法只用到 np.zeros / np.concatenate / 切片, 补个最小 shim 就够。
if M.cv2 is None:
    M.np = np

    class _Cv2Shim(object):
        @staticmethod
        def hconcat(frames):
            return np.concatenate(frames, axis=1)

    M.cv2 = _Cv2Shim()
    print("[env] 本机无 cv2, 已注入最小 shim (只支持 hconcat)")

CAM0, CAM1 = 0x00, M.DUAL_SRC1          # cam0 -> 0x00, cam1 -> 0x11
FAIL = []


def mk_raw(src, w=1920, h=1080):
    """造一块 NV16 原始缓冲, 头 4 字节按 FPGA 的帧标记填。"""
    b = np.zeros((1, w * h * 2), np.uint8)
    if src is not None:
        b[0, 0] = M.DUAL_MAGIC0
        b[0, 1] = M.DUAL_MAGIC1
        b[0, 2] = src
        b[0, 3] = M.DUAL_MAGIC3
    return b


def check(name, cond, detail=""):
    if cond:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s  %s" % (name, detail))
        FAIL.append(name)


def frame(tag, h=540, w=960):
    """造一帧 BGR, 用亮度区分左右来源: cam0=30, cam1=200。"""
    f = np.zeros((h, w, 3), np.uint8)
    f[:, :] = (30 if tag == 0 else 200, 10, 10)
    return f


class FakeHub(object):
    def publish(self, *a, **k):
        pass


def mk_cap(dual=True):
    args = types.SimpleNamespace(
        device="/dev/video22", fourcc="NV16", conv_threads=1, enc_threads=1,
        stream_width=1920, v4l2ctl="v4l2-ctl", yuv_matrix="709",
        yuv_range="limited", swap_uv=0)
    cap = M.OpenCVCapture(FakeHub(), M.ParamStore(None), args)
    cap._w, cap._h = 1920, 1080
    cap._dual_now = dual
    if dual:
        # 模拟"两路都活着", 否则 _dual_compose 会把 cam0 判成掉线
        cap._dual_ts = {0: time.time(), 1: time.time()}
    return cap


def feed(cap, src, seq, t=0.0):
    """模拟采集线程: 更新本路最后出现时刻, 再走一次拼接。"""
    cap._dual_ts[src] = time.time()
    return cap._dual_compose(src, frame(src), 1000.0 + t, seq)


# ---------------------------------------------------------------- 帧标记解析
print("[1] _peek_dual_src (NV16 头 4 字节 = 0xA5 0x5A src 0xFF)")
cap = mk_cap(dual=False)
check("cam0 标记 -> 0", cap._peek_dual_src(mk_raw(CAM0)) == 0,
      cap._peek_dual_src(mk_raw(CAM0)))
check("cam1 标记 -> 1", cap._peek_dual_src(mk_raw(CAM1)) == 1,
      cap._peek_dual_src(mk_raw(CAM1)))
check("无标记 -> None", cap._peek_dual_src(mk_raw(None)) is None)
_bad = mk_raw(CAM0)
_bad[0, 1] = 0x00                      # 破坏 magic
check("magic 错 -> None", cap._peek_dual_src(_bad) is None)
_bad2 = mk_raw(CAM0)
_bad2[0, 3] = 0x7F                     # 破坏尾字节
check("尾字节错 -> None", cap._peek_dual_src(_bad2) is None)
check("空帧 -> None", cap._peek_dual_src(None) is None)
check("太短 -> None", cap._peek_dual_src(np.zeros((1, 3), np.uint8)) is None)

# ---------------------------------------------------------------- 交替流
print("[2] _dual_compose 交替流 0,1,0,1,0,1,0,1")
M.DUAL_STAT.update({"pair": 0, "single": 0, "half_skip": 0, "dup_skip": 0})
cap = mk_cap()
outs = []
for i, s in enumerate([0, 1, 0, 1, 0, 1, 0, 1]):
    g = feed(cap, s, i + 1, i * 0.016)
    if g is not None:
        outs.append((i + 1, g))
tags = [t for _, (_, _, t) in outs]
check("8 帧输入 -> 发布 4 次 (每对一次, 输出 30fps)", len(outs) == 4, tags)
check("第 1 次是单路(cam1 还没到)", tags[0] == "cam0", tags)
check("后 3 次都是 dual", tags[1:] == ["dual"] * 3, tags)
check("全部尺寸 540x1920",
      all(f.shape[:2] == (540, 1920) for _, (f, _, _) in outs),
      [f.shape for _, (f, _, _) in outs])
check("pair == 3", M.DUAL_STAT["pair"] == 3, M.DUAL_STAT)
check("half_skip == 4 (cam1 到达那 4 次)", M.DUAL_STAT["half_skip"] == 4,
      M.DUAL_STAT)
f0 = outs[-1][1][0]
check("左半 = cam0 (30)", int(f0[:, :960].max()) == 30, int(f0[:, :960].max()))
check("右半 = cam1 (200)", int(f0[:, 960:].max()) == 200,
      int(f0[:, 960:].max()))

# ---------------------------------------------------------------- 去重
print("[3] 同一对不能连发两次")
cap = mk_cap()
g1 = feed(cap, 0, 1)
check("cam0 先到 -> 单路 cam0", g1 is not None and g1[2] == "cam0", g1)
g2 = feed(cap, 1, 2)
check("cam1 到达但不发布(非主路)", g2 is None, g2)
g3 = feed(cap, 0, 3)
check("cam0 再到达 -> dual", g3 is not None and g3[2] == "dual", g3)
# 真正会重复的场景: 两个编码线程拿到同一个 seq(理论上不该发生, 这是防守)
g4 = cap._dual_compose(0, frame(0), 1000.4, 3)
check("同一对重复 -> None", g4 is None, g4)

# ---------------------------------------------------------------- 单路降级
print("[4] 单路降级: 只有 cam0 (cam1 从未出现)")
M.DUAL_STAT.update({"pair": 0, "single": 0, "half_skip": 0})
cap = mk_cap()
outs = [feed(cap, 0, i + 1, i) for i in range(4)]
outs = [g for g in outs if g is not None]
check("cam0 活着时按主路节流 -> 4 次发布", len(outs) == 4, len(outs))
check("tag 都是 cam0", all(t == "cam0" for _, _, t in outs), outs)
check("右半涂黑", bool((outs[0][0][:, 960:] == 0).all()),
      outs[0][0][:, 960:].max())
check("左半有画面", int(outs[0][0][:, :960].max()) == 30,
      int(outs[0][0][:, :960].max()))

print("[5] 单路降级: cam0 掉线, 只剩 cam1")
cap = mk_cap()
cap._dual_ts[0] = time.time() - 100.0        # cam0 早已超时
g = feed(cap, 1, 1)
check("主路退化成 cam1 也能发布", g is not None, g)
check("tag == cam1", g is not None and g[2] == "cam1", g)
check("左半涂黑", bool((g[0][:, :960] == 0).all()), g[0][:, :960].max())
check("右半有画面", int(g[0][:, 960:].max()) == 200, int(g[0][:, 960:].max()))

# ---------------------------------------------------------------- 异常
print("[6] 两路尺寸不一致 -> 不 hstack, 退化成单路")
M.DUAL_STAT["shape_skip"] = 0
cap = mk_cap()
feed(cap, 0, 1)
g = cap._dual_compose(1, np.full((540, 862, 3), 200, np.uint8), 1001.0, 2)
check("cam1 不发布(非主路)", g is None, g)
cap._dual_ts[1] = time.time()
g = cap._dual_compose(0, frame(0), 1001.1, 3)
check("shape_skip 被触发", M.DUAL_STAT["shape_skip"] >= 1, M.DUAL_STAT)
check("仍出图(cam0 单路)", g is not None and g[2] == "cam0", g)
check("宽度仍是 2x960", g is not None and g[0].shape[:2] == (540, 1920),
      None if g is None else g[0].shape)

# ---------------------------------------------------------------- 目标尺寸
print("[7] _target_size 双目半宽")
cap = mk_cap(dual=False)
check("单目 1920x1080", cap._target_size(1.0) == (1920, 1080),
      cap._target_size(1.0))
cap._dual_now = True
check("双目 960x540", cap._target_size(1.0) == (960, 540),
      cap._target_size(1.0))
check("双目 scale=1.5 -> 1440x810", cap._target_size(1.5) == (1440, 810),
      cap._target_size(1.5))
check("双目 scale=0.5 -> 480x270", cap._target_size(0.5) == (480, 270),
      cap._target_size(0.5))
cap._dual_now = False
check("退出双目回到 1920", cap._target_size(1.0) == (1920, 1080),
      cap._target_size(1.0))

# ---------------------------------------------------------------- 状态
print("[8] dual_status 结构")
cap = mk_cap()
st = cap.dual_status()
for k in ("enabled", "active", "last_src", "cam0_age_ms", "cam1_age_ms", "stat"):
    check("有键 %s" % k, k in st, list(st.keys()))
check("active == True", st["active"] is True, st["active"])

print("")
if FAIL:
    print("FAILED: %d 项  %s" % (len(FAIL), FAIL))
    sys.exit(1)
print("PASS: 双目拼接逻辑全部通过")
