# -*- coding: utf-8 -*-
"""动作识别引擎：**轻量模型为主 + 空间几何(越界)为辅**。

替换关系
--------
原来的 `ActionRecognizer`（action_rules.py）是纯几何规则：阈值全靠手调，
日常小动作很容易踩到阈值，误报/漏报来回摇摆。本模块用训练出来的骨架分类器
替代 10 个"姿态动作"，只保留 **intrude（越界）** 这一条空间规则 ——
它是多边形几何，不是动作，模型也没法替。

输出契约与 ActionRecognizer.update 完全一致，所以 ai_overlay 里可以无缝切换：
    r['actions'] = [{'label','cn','en','color','level','score','dur'}, ...]
    r['risk']    = max(level)

三级兜底（任何一级失败都自动降级，不会让 AI 整个不可用）
  1. rknnlite + action_net.rknn   —— NPU，<1ms
  2. action_np.NumpyActionNet     —— CPU numpy，~10ms/人
  3. 不启用（调用方退回 ActionRecognizer 几何规则）
"""
import collections
import os
import time

import numpy as np

try:
    from action_seq import SeqBuffer, T_LEN
    from action_rules import ACTION_META, LEVEL_ALARM
except Exception:                                          # noqa: BLE001
    from .action_seq import SeqBuffer, T_LEN               # type: ignore
    from .action_rules import ACTION_META, LEVEL_ALARM     # type: ignore

# ⚠ 必须与 rk/ai/convert/action_spec.py 的 ACTION_CLASSES **完全一致**
#   （板上没有 action_spec.py，所以这里留一份副本；改一处就要改两处）
DEFAULT_CLASSES = ['idle', 'fall', 'climb', 'fight', 'run',
                   'handup', 'squat', 'swing', 'throw', 'photo']

NOSE, LW, RW, LA, RA = 0, 9, 10, 15, 16


# ---------------------------------------------------------------- 模型封装

class ActionModel(object):
    """rknn 优先，其次 numpy。`ok=False` 表示两条路都不可用。"""

    def __init__(self, rknn_path='', npz_path='', classes=None, core_mask=None,
                 name='action'):
        self.name = name
        self.backend = ''
        self.ok = False
        self.err = ''
        self.classes = list(classes or DEFAULT_CLASSES)
        self.infer_ms = 0.0
        self._rk = None
        self._np = None

        if rknn_path and os.path.isfile(rknn_path):
            try:
                from rknnlite.api import RKNNLite      # noqa: WPS433
                rk = RKNNLite(verbose=False)
                if rk.load_rknn(rknn_path) != 0:
                    raise RuntimeError('load_rknn 失败')
                if core_mask is None:
                    core_mask = getattr(RKNNLite, 'NPU_CORE_0_1', None)
                cm = RKNNLite.NPU_CORE_AUTO if core_mask is None else core_mask
                if rk.init_runtime(core_mask=cm) != 0:
                    if cm == RKNNLite.NPU_CORE_AUTO or \
                            rk.init_runtime(core_mask=RKNNLite.NPU_CORE_AUTO) != 0:
                        raise RuntimeError('init_runtime 失败')
                self._rk = rk
                self.backend = 'rknn'
                self.ok = True
                return
            except Exception as e:                        # noqa: BLE001
                self.err = 'rknn: %s' % e

        if npz_path and os.path.isfile(npz_path):
            try:
                from action_np import NumpyActionNet   # noqa: WPS433
                self._np = NumpyActionNet(npz_path)
                self.backend = 'numpy'
                self.ok = True
                return
            except Exception as e:                        # noqa: BLE001
                self.err += ' | numpy: %s' % e

        if not self.err:
            self.err = '没有可用的动作模型文件'

    def predict(self, seq):
        """seq: (T,17,3) 归一化 -> probs (K,) / None"""
        if not self.ok:
            return None
        t0 = time.time()
        if self.backend == 'rknn':
            outs = self._rk.inference(inputs=[seq[None]], data_format='nhwc')
            logits = np.asarray(outs[0], np.float32).reshape(-1)
            e = np.exp(logits - logits.max())
            probs = e / e.sum()
        else:
            probs = self._np.predict_one(seq)
        self.infer_ms = (time.time() - t0) * 1000.0
        return probs.astype(np.float32)

    def release(self):
        if self._rk is not None:
            try:
                self._rk.release()
            except Exception:                             # noqa: BLE001
                pass
            self._rk = None


# ---------------------------------------------------------------- 运行时引擎

class _TrackState(object):
    __slots__ = ('buf', 'probs', 'last_run', 'cand', 'cand_t', 'active',
                 'last_alert', 'miss_t', 'foot')

    def __init__(self, maxlen=120):
        self.buf = SeqBuffer(maxlen=maxlen)
        self.probs = None
        self.last_run = 0.0
        self.cand = None
        self.cand_t = 0.0
        self.active = {}          # label -> (score, start_t)
        self.last_alert = 0.0
        self.miss_t = 0.0
        self.foot = None


class ActionEngine(object):
    """模型动作 + 越界几何。

    参数
    ----
    model      : ActionModel（必须 ok）
    alert_polygon : 归一化(0~1) 警戒多边形，给 intrude 用
    fps        : 模型推理频率（Hz）。默认 10——动作是秒级事件，10Hz 足够，
                 而且 1 次前向只占 AI 线程 0.2~0.5% 的时间。
    thresh     : top1 概率门限
    hold       : 该类别需要连续命中的时长（秒）
    clear      : 类别掉出 top1 多久后撤销
    smooth     : 概率 EMA 系数
    window     : 送模型的序列时长（秒），None=用满缓冲
    """

    def __init__(self, model, alert_polygon=None, fps=10.0, thresh=0.55,
                 hold=0.25, clear=0.5, smooth=0.5, cooldown=2.0,
                 window=None, box_margin=0.0):
        self.model = model
        self.alert_polygon = list(alert_polygon or [])
        self.period = 1.0 / max(1.0, float(fps))
        self.thresh = float(thresh)
        self.hold = float(hold)
        self.clear = float(clear)
        self.smooth = float(smooth)
        self.window = window
        self.cooldown = float(cooldown)
        self.box_margin = float(box_margin)
        self.tracks = {}
        self.events = collections.deque(maxlen=100)
        self.classes = list(getattr(model, 'classes', DEFAULT_CLASSES))
        # 与 ActionRecognizer 同名的可调参数容器：前端 /api/ai 的 tune 分支
        # 会无条件写这个 dict，保持一个空 dict 就不会报 AttributeError。
        self.tune = {}

    # ---------------------------------------------------------------- 调参/状态
    def apply(self, patch):
        """热更新（与 ActionRecognizer 的 tune 接口对齐，便于前端复用）。"""
        out = {}
        if not isinstance(patch, dict):
            return out
        for k in ('thresh', 'hold', 'clear', 'smooth', 'cooldown'):
            if k in patch:
                try:
                    setattr(self, k, float(patch[k]))
                    out[k] = getattr(self, k)
                except (TypeError, ValueError):
                    pass
        if 'zone' in patch:
            self.alert_polygon = [(float(x), float(y)) for x, y in (patch['zone'] or [])]
            out['zone'] = self.alert_polygon
        return out

    def status(self):
        return {'backend': getattr(self.model, 'backend', ''),
                'classes': self.classes,
                'infer_ms': round(float(getattr(self.model, 'infer_ms', 0.0)), 2),
                'thresh': self.thresh, 'hold': self.hold,
                'fps': round(1.0 / self.period, 1),
                'zone': self.alert_polygon}

    # ---------------------------------------------------------------- 主循环
    def update(self, t, results, frame_size=None):
        alive = set()
        for r in results:
            tid = r.get('tid', -1)
            alive.add(tid)
            st = self.tracks.get(tid)
            if st is None:
                st = self.tracks[tid] = _TrackState()

            kps = r.get('kps')
            box = r.get('box')
            if kps is not None and box is not None:
                st.buf.push(t, kps, box)

            labels = []
            # ---- 1) 模型动作
            if st.buf.ready(T_LEN) and (t - st.last_run) >= self.period:
                st.last_run = t
                probs = self.model.predict(st.buf.build(T_LEN, self.window))
                if probs is not None and len(probs) == len(self.classes):
                    st.probs = probs if st.probs is None else (
                        self.smooth * st.probs + (1.0 - self.smooth) * probs)
                    labels.extend(self._hysteresis(st, t, st.probs))

            # ---- 2) 越界（几何，与模型并行）
            if self.alert_polygon and kps is not None:
                lab = self._intrude(st, t, kps, frame_size)
                if lab is not None:
                    labels.append(lab)

            # ---- 3) 输出
            labels.sort(key=lambda a: (-a['level'], -a['score']))
            r['actions'] = labels
            r['risk'] = max([a['level'] for a in labels], default=0)
            for a in labels:
                if a['level'] >= LEVEL_ALARM and t - st.last_alert > self.cooldown:
                    st.last_alert = t
                    self.events.append({'t': t, 'tid': tid, 'label': a['label'],
                                        'cn': a['cn'], 'en': a['en'],
                                        'score': a['score']})

        for tid in list(self.tracks.keys()):
            if tid not in alive:
                self.tracks.pop(tid, None)
        return results

    # ---------------------------------------------------------------- 内部
    def _hysteresis(self, st, t, probs):
        """类别需要连续 hold 秒命中才上报；掉出后 clear 秒撤销。"""
        idx = int(probs.argmax())
        label = self.classes[idx]
        score = float(probs[idx])
        out = []

        if label == 'idle' or score < self.thresh:
            if st.cand is not None and t - st.cand_t > self.clear:
                st.cand = None
            if st.active and t - st.miss_t > self.clear:
                st.active.clear()
            return out

        if label == st.cand:
            if t - st.cand_t >= self.hold:
                st.active[label] = (score, st.cand_t)
        else:
            st.cand, st.cand_t = label, t
        st.miss_t = t

        for lab, (sc, t0) in list(st.active.items()):
            cn, en, color, level = ACTION_META.get(lab, (lab, lab, (200, 200, 200), 0))
            out.append({'label': lab, 'cn': cn, 'en': en, 'color': color,
                        'level': level, 'score': float(sc), 'dur': float(t - t0)})
        return out

    def _intrude(self, st, t, kps, frame_size):
        try:
            k = np.asarray(kps, np.float32).reshape(-1, 3)
        except Exception:                                 # noqa: BLE001
            return None
        pts = [k[i] for i in (LA, RA) if k[i, 2] > 0]
        if not pts:
            return None
        st.foot = (float(sum(p[0] for p in pts) / len(pts)),
                   float(sum(p[1] for p in pts) / len(pts)))
        poly = self.alert_polygon
        if frame_size:
            w, h = frame_size
            if all(abs(x) <= 1.5 and abs(y) <= 1.5 for x, y in poly):
                poly = [(x * w, y * h) for x, y in poly]
        if not _point_in_poly(st.foot, poly):
            return None
        # 越界同样给 0.3s 去抖：用 active 表实现
        rec = st.active.get('intrude')
        if rec is None:
            st.active['intrude'] = (0.9, t)
            return None
        if t - rec[1] < 0.3:
            return None
        cn, en, color, level = ACTION_META.get('intrude', ('越界', 'Intrude', (0, 165, 255), 1))
        return {'label': 'intrude', 'cn': cn, 'en': en, 'color': color,
                'level': level, 'score': 0.9, 'dur': float(t - rec[1])}


def _point_in_poly(pt, poly):
    """射线法。与 action_rules.TrackState._point_in_poly 同一算法。"""
    x, y = pt
    inside = False
    n = len(poly)
    if n < 3:
        return False
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y):
            xint = (x2 - x1) * (y - y1) / (y2 - y1 + 1e-9) + x1
            if x < xint:
                inside = not inside
    return inside
