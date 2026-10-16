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
               "show_score", "show_label", "show_hud", "zone", "tune",
               "preset", "spread_pose")

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


class AiOverlay(object):
    """线程安全的 AI 叠加器。编码线程调 submit()/draw()，本类内部线程负责推理。"""

    def __init__(self, ai_dir=None, det_model=None, pose_model=None,
                 ai_fps=6.0, det_conf=0.35, nms_thres=0.45, kpt_conf=0.30,
                 max_persons=4, roi_expand=1.15, kpt_margin=0.15,
                 kpt_scale_max=1.2, det_interval=2, copy_frame=False,
                 spread_pose=True,
                 source="raw", enabled=True,
                 zone=None, show_skeleton=True, show_score=True, show_label=True,
                 show_hud=False, state_path=None, verbose=False):
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
        # 是否在推理前拷贝整帧：不拷贝可省 ~2.5ms/帧，代价是编码线程可能
        # 已在同一数组上画了几笔标注（对检测影响可忽略）
        self.copy_frame = bool(copy_frame)
        self.show_skeleton = bool(show_skeleton)
        self.show_score = bool(show_score)
        self.show_label = bool(show_label)
        self.show_hud = bool(show_hud)
        self.verbose = bool(verbose)
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
        self._stats = {"n": 0, "t0": time.time(), "det_n": 0, "pose_n": 0}

        self._stop = threading.Event()
        self._thr = None

        # 恢复上次的 AI 设置（页面重连 / 服务重启后不用重新调一遍）
        self._state_path = state_path
        self._restore_state()

    # ------------------------------------------------------------------ 生命周期
    @property
    def active(self):
        """编码线程只需判断这个：假 = 完全不碰帧。"""
        return bool(self.enabled and self.source == "ai")

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
        except Exception as e:                                  # noqa: BLE001
            self.err = "导入 AI 模块失败(%s): %s" % (board, e)
            return False

        det = self._build(self.det_model, self.pose_model)
        if det is None:
            return False
        self.detector = det
        self.tracker = SimpleTracker()
        self.actions = ActionRecognizer(alert_polygon=self.zone,
                                        box_margin=self.box_margin)
        self.ok = True
        if not det.pose or not det.pose.ok:
            self.err = "姿态模型不可用(仅画人体框): %s" % (
                det.pose.err if det.pose else "未指定")
        print("[ai] 模型已加载: det=%s pose=%s (det %s / pose %s 输入, 档位 %s)"
              % ("OK" if det.det.ok else "FAIL",
                 "OK" if (det.pose and det.pose.ok) else "FAIL",
                 getattr(det, "det_size", 0), getattr(det, "pose_size", 0),
                 self.preset))
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
                               spread_pose=self.spread_pose)
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
        """投递最新帧（只存引用；真正要推理时内部才拷贝）。"""
        if not self.active or frame is None:
            return
        with self._lock:
            self._frame = frame
            self._seq += 1

    def draw(self, frame):
        """把最近一次的标注画到 frame 上（就地）。无结果时原样返回。"""
        if not self.active or frame is None:
            return frame
        with self._lock:
            res = self._result
        if not res:
            return frame
        try:
            from det_core import draw_person
        except Exception:                                       # noqa: BLE001
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
        if not self._load():
            print("[ai] 未启用: %s" % self.err, file=sys.stderr)
            return
        last_seq = -1
        while not self._stop.is_set():
            if not self.active:
                time.sleep(0.1)
                continue
            with self._lock:
                fr, sq = self._frame, self._seq
            if fr is None or sq == last_seq:
                time.sleep(0.005)
                continue
            last_seq = sq

            t0 = time.time()
            # 默认不拷贝：编码线程最多在同一块内存上画几笔，对检测影响可忽略；
            # 要“绝对干净”就把 copy_frame 打开（多花 ~2.5ms/帧）。
            img = fr.copy() if self.copy_frame else fr
            try:
                # _det_lock：推理期间不许换模型（switch_pose 会 release 旧实例）
                t1 = time.time()
                with self._det_lock:
                    dets = self.detector.run(img)
                    t2 = time.time()
                    dets = self.tracker.update(t0, dets)
                    dets = self.actions.update(t0, dets)
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

    # ------------------------------------------------------------------ 状态 / 调参
    def status(self):
        with self._lock:
            res = list(self._result)
            rt = self._result_t
        dets = []
        for d in res:
            kps = d.get("kps")
            n_kpt = 0
            if kps is not None:
                try:
                    n_kpt = int((kps[:, 2] > 0).sum())
                except Exception:                               # noqa: BLE001
                    n_kpt = 0
            dets.append({
                "tid": d.get("tid"),
                "box": [int(v) for v in d.get("box", [0, 0, 0, 0])],
                "score": round(float(d.get("score", 0)), 3),
                "risk": d.get("risk", 0),
                "n_kpt": n_kpt,
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
            if src in ("raw", "ai"):
                self.source = src
        for k in ("show_skeleton", "show_score", "show_label", "show_hud"):
            if k in patch:
                setattr(self, k, bool(patch[k]))
        if "ai_fps" in patch:
            self.ai_fps = max(0.5, min(30.0, float(patch["ai_fps"])))
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
        if self.source != "ai":
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
