#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cloud_agent.py —— 板端上行代理（RK3576）
职责：
  1) 每 5s 把状态/参数快照 POST 到云端 /api/ingest（gzip，约 0.5KB/次）
  2) AI 危险动作事件 / 链路异常 / 温度磁盘异常 → /api/alarm + 抓拍小图
  3) 长轮询 /api/commands 取云端下发的指令，打到本地 9012，再把结果回传
  4) 看板点“抓拍一张” → 本地取一张 960px 图 → POST /api/live（约 40KB）
带宽纪律（服务器只有 3Mbps）：
  * 报警图固定 640px / q55（约 20~30KB），失败就不传图，绝不重试刷流量
  * 同标签 15s 内只报一次；资源类报警不带图
  * 指令结果 msg 截断 200 字
依赖：仅标准库。缩图优先用 cv2（板端 mlk-ov 环境自带），没有就原样上传。
用法：
    python3 cloud_agent.py --server https://<SERVER_DOMAIN> \
        --token-file /root/rk/cloud/token --name "AFC03 IMX415"

    python3 cloud_agent.py --server http://127.0.0.1:9080 --token dev --once
"""
from __future__ import print_function

import argparse
import gzip
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import shutil
import threading
import time
import urllib.error
import urllib.request

APP = "cloud-agent"
VER = "1.0"


def log(msg):
    sys.stdout.write("[%s] %s\n" % (time.strftime("%m-%d %H:%M:%S"), msg))
    sys.stdout.flush()


def now():
    return time.time()


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Link(object):
    def __init__(self, base, token=None, timeout=6.0, insecure=False):
        self.base = base.rstrip("/")
        self.token = token or ""
        self.timeout = timeout
        self.ctx = None
        if self.base.startswith("https"):
            self.ctx = ssl.create_default_context()
            if insecure:
                self.ctx.check_hostname = False
                self.ctx.verify_mode = ssl.CERT_NONE

    def raw(self, method, path, data=None, headers=None, timeout=None):
        url = self.base + path
        h = {"User-Agent": "%s/%s" % (APP, VER)}
        if self.token:
            h["X-Token"] = self.token
        if headers:
            h.update(headers)
        req = urllib.request.Request(url, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout,
                                        context=self.ctx) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except Exception as e:                                # noqa: BLE001
            raise IOError("%s: %s" % (type(e).__name__, e))

    def get(self, path, timeout=None):
        return self.raw("GET", path, timeout=timeout)

    def get_json(self, path, timeout=None):
        code, body = self.get(path, timeout)
        if code != 200:
            return None
        try:
            return json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    def get_bytes(self, path, timeout=None):
        code, body = self.get(path, timeout)
        return body if code == 200 else None

    def post(self, path, obj, gz=True, timeout=None):
        raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        h = {"Content-Type": "application/json; charset=utf-8"}
        if gz and len(raw) > 512:
            raw = gzip.compress(raw, 6)
            h["Content-Encoding"] = "gzip"
        return self.raw("POST", path, raw, h, timeout)

    def post_bytes(self, path, data, ctype="application/octet-stream", timeout=None):
        return self.raw("POST", path, data, {"Content-Type": ctype}, timeout)


# ---------------------------------------------------------------------------
# 选配：本地缩图（板端已有 cv2 就几乎零成本）
# ---------------------------------------------------------------------------
_CV = None
_PIL = None


def shrink_jpeg(jpeg, maxw=640, quality=55):
    global _CV, _PIL
    if not jpeg:
        return jpeg
    if _CV is None and _PIL is None:
        try:
            import cv2 as _c
            _CV = _c
        except Exception:                                     # noqa: BLE001
            try:
                from PIL import Image as _I
                import io as _io
                _PIL = (_I, _io)
            except Exception:                                 # noqa: BLE001
                _PIL = False
    try:
        if _CV:
            import numpy as np
            img = _CV.imdecode(np.frombuffer(jpeg, np.uint8), _CV.IMREAD_COLOR)
            if img is None:
                return jpeg
            h, w = img.shape[:2]
            if w <= maxw:
                return jpeg
            nh = max(2, int(round(h * float(maxw) / w)))
            # ★ 板端 INTER_AREA 没有 SIMD，极慢；缩图必须用 INTER_LINEAR
            out = _CV.resize(img, (int(maxw), nh), interpolation=_CV.INTER_LINEAR)
            ok, enc = _CV.imencode(".jpg", out,
                                   [int(_CV.IMWRITE_JPEG_QUALITY), int(quality)])
            return enc.tobytes() if ok else jpeg
        if _PIL:
            Image, io = _PIL
            im = Image.open(io.BytesIO(jpeg)).convert("RGB")
            if im.width <= maxw:
                return jpeg
            im = im.resize((maxw, max(2, int(im.height * maxw / im.width))))
            b = io.BytesIO()
            im.save(b, "JPEG", quality=int(quality), optimize=True)
            return b.getvalue()
    except Exception as e:                                    # noqa: BLE001
        log("shrink failed: %s" % e)
    return jpeg


# ---------------------------------------------------------------------------
# 本机资源（板端 9012 没有暴露温度/磁盘，直接读 /sys 与 statvfs）
# ---------------------------------------------------------------------------
def read_temp():
    best = None
    for i in range(6):
        p = "/sys/class/thermal/thermal_zone%d/temp" % i
        try:
            with open(p, "r") as f:
                v = int(f.read().strip()) / 1000.0
        except Exception:                                     # noqa: BLE001
            continue
        if 5 < v < 150:
            best = v if best is None else max(best, v)
    return round(best, 1) if best is not None else None


def read_disk():
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if total:
            return round(100.0 * (total - free) / total, 1)
    except Exception:                                         # noqa: BLE001
        pass
    return None


def read_uptime():
    try:
        with open("/proc/uptime", "r") as f:
            return int(float(f.read().split()[0]))
    except Exception:                                         # noqa: BLE001
        return None


def detect_ip():
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show"],
                             capture_output=True, text=True, timeout=2).stdout
        for line in out.splitlines():
            p = line.split()
            if "inet" not in p:
                continue
            addr = p[p.index("inet") + 1].split("/")[0]
            if not addr.startswith("127."):
                return addr
    except Exception:                                         # noqa: BLE001
        pass
    return None


# ---------------------------------------------------------------------------
# 视频：最近 10s 环形缓存（SD 卡）+ 事件前后 5s 合成 MP4
#   * 抓帧走 9012 的 /snapshot.jpg?w=&q=（缩图在 web 进程里用 cv2 做，本进程仅标准库）
#   * 帧很小：640x360 / q50 / 8fps ≈ 7KB/帧 ≈ 55KB/s，SD 卡压力小
#   * 合成走 gst：mppjpegdec（硬解）→ mpph264enc（硬编）→ mp4mux，不依赖 ffmpeg
#   * 上传失败留在本地，后台循环重试；本地目录滚动上限 clip-total-mb（默认 1GB）
# ---------------------------------------------------------------------------
class ClipRing(object):
    def __init__(self, a, local, cloud):
        self.a = a
        self.local = local
        self.cloud = cloud
        self.ring_dir = a.ring_dir
        self.clip_dir = a.clip_dir
        self.fps = max(2, int(a.ring_fps))
        # 保留 pre + post + 余量：事件后要等 post 秒才能合成，
        # 若只留 pre+3，开头的帧在合成前就被删了（实测 multifilesrc 直接报错）
        self.keep = max(4.0, float(a.clip_pre) + float(a.clip_post) + 3.5)
        self.lock = threading.Lock()
        self.frames = []            # [(ts, idx)]，idx 对应 r%06d.jpg
        self.idx = 0
        self.stop = threading.Event()
        self.sent = 0
        self.failed = 0

    # ---- 生命周期 ----
    def start(self):
        try:
            os.makedirs(self.ring_dir, exist_ok=True)
            os.makedirs(self.clip_dir, exist_ok=True)
        except OSError as e:
            log("clip: 建目录失败 %s（视频功能关闭）" % e)
            return
        self.clean_ring()
        threading.Thread(target=self.loop, name="ring", daemon=True).start()
        threading.Thread(target=self.retry_loop, name="clipretry",
                         daemon=True).start()
        log("clip: 环形缓存 %s (%d fps, 保留 %.0fs) | 待传目录 %s"
            % (self.ring_dir, self.fps, self.keep, self.clip_dir))

    def clean_ring(self):
        try:
            for n in os.listdir(self.ring_dir):
                if n.startswith("r") and n.endswith(".jpg"):
                    try:
                        os.remove(os.path.join(self.ring_dir, n))
                    except OSError:
                        pass
        except OSError:
            pass

    # ---- 采集 ----
    def loop(self):
        dt = 1.0 / self.fps
        while not self.stop.is_set():
            t0 = now()
            jpg = None
            try:
                q = "/snapshot.jpg?w=%d&q=%d&full=0" % (self.a.clip_width,
                                                        self.a.clip_quality)
                jpg = self.local.get_bytes(q, timeout=4)
            except Exception:                                 # noqa: BLE001
                jpg = None
            if jpg and len(jpg) > 1000 and jpg.startswith(b"\xff\xd8"):
                self.push(jpg)
            rest = dt - (now() - t0)
            if rest > 0:
                self.stop.wait(rest)

    def push(self, jpg):
        self.idx = (self.idx + 1) % 1000000
        p = os.path.join(self.ring_dir, "r%06d.jpg" % self.idx)
        try:
            with open(p, "wb") as f:
                f.write(jpg)
        except OSError:
            return
        t = now()
        cut = t - self.keep
        with self.lock:
            self.frames.append((t, self.idx))
            drop = [x[1] for x in self.frames if x[0] < cut]
            self.frames = [x for x in self.frames if x[0] >= cut]
        for i in drop:
            try:
                os.remove(os.path.join(self.ring_dir, "r%06d.jpg" % i))
            except OSError:
                pass

    # ---- 事件 ----
    def trigger(self, aid, t_event):
        """异步合成 [t-5, t+5] 的 MP4 并上传（不阻塞心跳线程）。"""
        if not aid or not getattr(self.a, "clip_on", True):
            return
        threading.Thread(target=self._make_and_send, args=(aid, float(t_event)),
                         name="clip", daemon=True).start()

    def _make_and_send(self, aid, t_event):
        try:
            wait = (t_event + float(self.a.clip_post)) - now()
            if wait > 0:
                time.sleep(wait)                     # 等后 5 秒录完
            fn = "%s_%g.mp4" % (aid, float(self.a.clip_pre) + float(self.a.clip_post))
            out = os.path.join(self.clip_dir, fn)
            sec = self.make_clip(t_event, out)
            if not sec:
                self.failed += 1
                return
            log("clip: 合成 %s %.1fs %dKB" % (aid, sec, os.path.getsize(out) // 1024))
            self.send(aid, out, sec)
        except Exception as e:                                # noqa: BLE001
            log("clip: 合成异常 %s" % e)

    def make_clip(self, t_event, out):
        """把缓存里 [t-pre, t+post] 的帧用硬件编解码合成一个 mp4，返回时长。"""
        pre, post = float(self.a.clip_pre), float(self.a.clip_post)
        with self.lock:
            sel = sorted(i for (ts, i) in self.frames
                         if t_event - pre - 0.3 <= ts <= t_event + post)
        if len(sel) < 4:
            log("clip: 缓存帧不足(%d)" % len(sel))
            return 0.0
        # 先把选中的帧硬链接到临时目录并重新连续编号：
        # 环形缓存同时在删旧帧，直接读原目录会被 multifilesrc 判为文件缺失
        tmp = tempfile.mkdtemp(prefix="mk", dir=self.clip_dir)
        n, first, last = 0, sel[0], sel[-1]
        try:
            for i in range(first, last + 1):
                src = os.path.join(self.ring_dir, "r%06d.jpg" % i)
                if not os.path.exists(src):
                    continue
                n += 1
                dst = os.path.join(tmp, "f%06d.jpg" % n)
                try:
                    os.link(src, dst)
                except OSError:
                    shutil.copyfile(src, dst)
            if n < 4:
                log("clip: 可用帧不足(%d)" % n)
                return 0.0
            sec = float(n) / self.fps
            base = [self.a.gst, "-q",
                    "multifilesrc", "location=%s/f%%06d.jpg" % tmp,
                    "caps=image/jpeg,framerate=%d/1" % self.fps,
                    "start-index=1", "stop-index=%d" % n, "!",
                    "jpegparse", "!", "mppjpegdec", "!",
                    "videorate", "!",
                    "video/x-raw,format=NV12,framerate=%d/1" % self.fps, "!",
                    "mpph264enc", "rc-mode=cbr", "bps=%d" % int(self.a.clip_bps),
                    "gop=%d" % (self.fps * 2), "!",
                    "h264parse", "!"]
            # faststart：moov 放前面，浏览器可边下边播；老 gst 没有该属性就退回普通封装
            tails = [["mp4mux", "faststart=true", "!", "filesink", "location=%s" % out],
                     ["mp4mux", "!", "filesink", "location=%s" % out]]
            err = ""
            for tail in tails:
                r = subprocess.run(base + tail, capture_output=True, text=True,
                                   timeout=120)
                if (r.returncode == 0 and os.path.exists(out)
                        and os.path.getsize(out) >= 512):
                    return sec
                err = "rc=%s %s" % (r.returncode, (r.stderr or "")[-140:])
                try:
                    os.remove(out)
                except OSError:
                    pass
            log("clip: gst 失败 %s" % err)
            return 0.0
        except Exception as e:                                # noqa: BLE001
            log("clip: 合成异常 %s" % e)
            return 0.0
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # ---- 上传 ----
    def send(self, aid, path, sec):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            return False
        try:
            code, _raw = self.cloud.post_bytes(
                "/api/alarm/%s/clip?sec=%.1f" % (aid, sec or 0.0), data,
                "video/mp4", timeout=90)
        except Exception as e:                                # noqa: BLE001
            log("clip: 上传失败 %s（留本地重试）" % e)
            return False
        if code != 200:
            log("clip: 上传 HTTP %d（留本地重试）" % code)
            return False
        try:
            os.remove(path)
        except OSError:
            pass
        self.sent += 1
        log("clip: 已上传 %s %dKB" % (aid, len(data) // 1024))
        self.trim_clips()
        return True

    def retry_loop(self):
        while not self.stop.is_set():
            self.stop.wait(45)
            if self.stop.is_set():
                return
            try:
                names = sorted(n for n in os.listdir(self.clip_dir)
                               if n.endswith(".mp4"))
            except OSError:
                continue
            for n in names[:3]:
                p = os.path.join(self.clip_dir, n)
                aid, _, sec = n[:-4].rpartition("_")
                try:
                    s = float(sec)
                except ValueError:
                    s = 0.0
                self.send(aid or n[:-4], p, s)
            self.trim_clips()

    def trim_clips(self):
        """本地待传目录滚动上限（总大小），默认 1GB。"""
        cap = max(64, int(self.a.clip_total_mb)) * 1024 * 1024
        items, total = [], 0
        try:
            for n in os.listdir(self.clip_dir):
                if not n.endswith(".mp4"):
                    continue
                p = os.path.join(self.clip_dir, n)
                try:
                    st = os.stat(p)
                except OSError:
                    continue
                items.append((st.st_mtime, st.st_size, p))
                total += st.st_size
        except OSError:
            return
        if total <= cap:
            return
        items.sort()
        for _mt, sz, p in items:
            try:
                os.remove(p)
                log("clip: 滚动删除 %s" % os.path.basename(p))
            except OSError:
                pass
            total -= sz
            if total <= cap:
                break


PP_KEYS = ("PP_EN", "ADV_MODE", "ADV_SOBEL_SH", "ADV_THRESH", "ADV_MORPH_SEL",
           "ADV_MORPH_TH", "ADV_LAP_SH", "ADV_PREW_SH", "ADV_EMBOSS_GAIN",
           "ADV_EMBOSS_BIAS", "ADV_SHARP_GAIN", "BASIC_EN", "BASIC_GRAY",
           "BASIC_GAUSS", "BASIC_HE", "BASIC_CONTRAST", "BASIC_KER",
           "BASIC_HE_CLIP", "BASIC_HE_TEMP", "BASIC_LINEFIX")


class Agent(object):
    def __init__(self, a):
        self.a = a
        self.local = Link(a.local, timeout=6)
        self.cloud = Link(a.server, token=a.token, timeout=10,
                          insecure=a.insecure)
        self.ticks = 0
        self.sys_cache = {}
        self.fpga_cache = {}
        self.fpga_ok = None
        self.fpga_ts = 0
        self.seen_events = {}
        self.ai_baseline = False
        self.last_alarm = {}
        # 健康告警（link_down / fps_zero / fpga_err / disk_full / temp_high）
        # 是“持续状态”：只在从正常→异常的边沿报一次，恢复前完全静默。
        self.health_on = {}        # label -> 已上报且尚未恢复（首次上报时刻）
        self.recovered = []        # 待向云端声明“已恢复”的 label（ingest 成功后清空）
        self.fail_local = 0
        self.fail_cloud = 0
        self.fps_bad_since = 0
        self.ai_bad_since = 0
        self.node_ip = detect_ip()
        self.seq = 0
        self.stop = threading.Event()
        self.clips = ClipRing(a, self.local, self.cloud)

    # ---------------- 采集 ----------------
    def collect(self):
        self.ticks += 1
        st = None
        try:
            st = self.local.get_json("/api/status", timeout=4)
        except Exception:                                     # noqa: BLE001
            st = None

        if self.ticks % 2 == 1:
            try:
                s = self.local.get_json("/api/sys", timeout=4)
                if isinstance(s, dict):
                    self.sys_cache = s
            except Exception:                                 # noqa: BLE001
                pass

        if self.ticks % 3 == 1:
            try:
                f = self.local.get_json("/api/fpga?compact=1", timeout=4)
                if isinstance(f, dict):
                    self.fpga_cache = f
                    self.fpga_ok = bool(f.get("ok"))
                    self.fpga_ts = now()
            except Exception:                                 # noqa: BLE001
                self.fpga_ok = None

        ai = None
        try:
            ai = self.local.get_json("/api/ai", timeout=3)
        except Exception:                                     # noqa: BLE001
            ai = None
        if isinstance(ai, dict) and not ai.get("ok", True):
            ai = None

        tel = self.build_tel(st, ai)
        self.check_health(tel, st, ai)
        self.scan_events(ai)
        return tel, st, ai

    def build_tel(self, st, ai):
        sysd = self.sys_cache or {}
        gpu = sysd.get("gpu") or {}
        npu = sysd.get("npu") or {}
        ram = sysd.get("ram") or {}
        lat = sysd.get("latency_ms") or {}
        fp = self.fpga_cache or {}
        regs = fp.get("regs") or {}
        phys = fp.get("phys") or {}
        st_params = (st or {}).get("params") or {}

        link = {
            "ok": st is not None,
            "fps": round(float((st or {}).get("fps") or 0), 1),
            "lat": lat.get("capture_to_ready"),
            "clients": (st or {}).get("clients"),
            "dev": self.a.device,
        }
        cam = {}
        for k in ("cam_exp_ms", "cam_exp_max_ms", "cam_gain_db", "ev",
                  "wb_r_pct", "wb_b_pct", "roi_pct", "res_mode", "fps"):
            if k in phys:
                cam[k] = phys[k]
        cam["base_fps"] = phys.get("fps")

        img = {}
        for k in ("brightness", "contrast", "saturation", "hue", "gamma",
                  "mirror", "flipv", "rotate", "scale", "quality", "fps"):
            if k in st_params:
                img[k] = st_params[k]

        pp = {}
        if self.ticks % 3 == 1:
            for k in PP_KEYS:
                if k in regs:
                    pp[k] = regs[k]

        risk = 0
        label = cn = None
        tid = None
        ai_out = {}
        if ai:
            dets = ai.get("detections") or []
            for d in dets:
                r = int(d.get("risk") or 0)
                if r > risk:
                    risk = r
                    tid = d.get("tid")
                    labels = d.get("labels") or []
                    cn = labels[0] if labels else None
                    ens = d.get("labels_en") or []
                    label = ens[0] if ens else None
            ai_out = {
                "enabled": bool(ai.get("enabled")),
                "active": bool(ai.get("active")),
                "source": ai.get("source"),
                "fps": ai.get("fps"),
                "ai_fps": ai.get("fps_target"),
                "persons": ai.get("persons"),
                "det_ms": ai.get("det_ms"),
                "pose_ms": ai.get("pose_ms"),
                "det_conf": ai.get("det_conf"),
                "nms_thres": ai.get("nms_thres"),
                "kpt_conf": ai.get("kpt_conf"),
                "kpt_margin": ai.get("kpt_margin"),
                "kpt_scale_max": ai.get("kpt_scale_max"),
                "roi_expand": ai.get("roi_expand"),
                "det_interval": ai.get("det_interval"),
                "pose_budget": ai.get("pose_budget"),
                "max_persons": ai.get("max_persons"),
                "tune": ai.get("tune") or {},
                "show_skeleton": ai.get("show_skeleton"),
                "show_score": ai.get("show_score"),
                "show_label": ai.get("show_label"),
                "show_hud": ai.get("show_hud"),
                "skeleton_only": ai.get("skeleton_only"),
                "zone": ai.get("zone") or [],
            }

        sys_out = {
            "cpu": (sysd.get("cpu") or {}).get("total")
            if isinstance(sysd.get("cpu"), dict) else sysd.get("cpu"),
            "npu": npu.get("load_pct"),
            "gpu": gpu.get("load_pct"),
            "mem": ram.get("pct"),
            "temp": read_temp(),
            "disk": read_disk(),
            "uptime": read_uptime(),
        }
        return {
            "link": link, "cam": cam, "img": img, "pp": pp,
            "ai": ai_out, "sys": sys_out,
            "alarm": {"risk": risk, "label": label, "cn": cn, "tid": tid},
            "health": {"warn": [], "crit": []},
        }

    # ---------------- 健康检查 ----------------
    def check_health(self, tel, st, ai):
        h = tel["health"]
        t = now()
        act = {}            # 本拍仍然异常的项: label -> (cn, lvl, note, with_img)

        if st is None:
            self.fail_local += 1
            if self.fail_local >= 3:
                h["crit"].append("板上推流服务不可达")
                tel["link"]["ok"] = False
                act["link_down"] = ("板上推流服务不可达", 2,
                                    "9012 连续 %d 次无响应" % self.fail_local, False)
        else:
            self.fail_local = 0
            fps = float(st.get("fps") or 0)
            if fps < 1.0:
                if not self.fps_bad_since:
                    self.fps_bad_since = t
                elif t - self.fps_bad_since > 12:
                    h["crit"].append("视频无帧")
                    act["fps_zero"] = ("视频无帧", 2,
                                       "fps=%.1f 持续 %ds" % (fps, int(t - self.fps_bad_since)), True)
            else:
                self.fps_bad_since = 0

        if ai is not None:
            # 只有“确实开着推理”时才算异常；source=raw 是用户主动关的
            if (ai.get("enabled") and (ai.get("source") or "ai") in ("ai", "detect")
                    and not ai.get("active")):
                if not self.ai_bad_since:
                    self.ai_bad_since = t
                elif t - self.ai_bad_since > 30:
                    h["warn"].append("AI 未出结果")
            else:
                self.ai_bad_since = 0
        elif self.fpga_ok is not None:
            # AI 是可选功能：没启用不算异常，最多在遥测里体现 ai={}
            pass

        if self.fpga_ok is False:
            h["warn"].append("FPGA I2C 读失败")
            act["fpga_err"] = ("FPGA 寄存器读取失败", 1, "i2c 读失败", False)
        camid = ((self.fpga_cache or {}).get("status") or {}).get("CAM_ID")
        if camid is not None and camid != 0xA5:
            h["warn"].append("FPGA 无参数区")

        sy = tel["sys"]
        if sy.get("disk") is not None:
            if sy["disk"] > 92:
                h["crit"].append("磁盘 %d%%" % sy["disk"])
                act["disk_full"] = ("板端磁盘将满", 2, "%0.1f%%" % sy["disk"], False)
            elif sy["disk"] > 85:
                h["warn"].append("磁盘 %d%%" % sy["disk"])
        if sy.get("temp") is not None:
            if sy["temp"] > 85:
                h["crit"].append("温度 %.0f°C" % sy["temp"])
                act["temp_high"] = ("板端温度过高", 2, "%.1f°C" % sy["temp"], False)
            elif sy["temp"] > 72:
                h["warn"].append("温度 %.0f°C" % sy["temp"])

        self.health_sync(act, h)

    def health_sync(self, act, h):
        """健康告警边沿触发：一次异常只报一次，恢复后才允许再报。
        以前每 cooldown×4（默认 60s）重复报一次，云端会堆一串同样的记录
        （看板上就是“磁盘将满 ×20”）。现在只在“正常→异常”时报一条，
        持续期间静默；恢复时把 label 放进 tel.health.ok，让云端关掉这一回合。
        推送失败不记为已报，下一拍（5s）重试，避免开机瞬间丢告警。
        """
        for label in list(self.health_on.keys()):
            if label not in act:
                self.health_on.pop(label, None)
                if label not in self.recovered:
                    self.recovered.append(label)
                log("health recovered: %s" % label)
        for label, (cn, lvl, note, with_img) in act.items():
            if label in self.health_on:
                continue
            if self.alarm(label, cn, lvl, "health", note=note, with_img=with_img):
                self.health_on[label] = now()
        h["ok"] = self.recovered[:]

    # ---------------- AI 事件 ----------------
    def scan_events(self, ai):
        if not isinstance(ai, dict):
            return
        evs = ai.get("events") or []
        t = now()
        for e in evs:
            try:
                key = (round(float(e.get("t") or 0), 2), e.get("tid"), e.get("label"))
            except Exception:                                 # noqa: BLE001
                continue
            if key in self.seen_events:
                continue
            self.seen_events[key] = t
            if not self.ai_baseline:
                continue
            self.alarm(str(e.get("label") or "alert"),
                       str(e.get("cn") or e.get("label") or "报警"), 2, "ai",
                       tid=e.get("tid"), score=float(e.get("score") or 0),
                       with_img=True,
                       metrics={"fps": (ai.get("fps") or 0),
                                "persons": ai.get("persons") or 0})
        if not self.ai_baseline and ai.get("ok", True):
            self.ai_baseline = True
            log("AI 事件基线已建立（%d 条历史事件不补发）" % len(evs))
        if len(self.seen_events) > 400:
            cut = t - 300
            self.seen_events = {k: v for k, v in self.seen_events.items() if v > cut}

    # ---------------- 报警 ----------------
    def alarm(self, label, cn, lvl=2, src="ai", tid=None, score=0.0,
              note="", with_img=True, metrics=None):
        """推一条报警，返回是否成功送达云端。
        health 类走边沿触发（由 health_sync 控制）：同一异常恢复前只报一次。
        其它（AI 事件）保留 cooldown 去抖。last_alarm 只在送达后才记，
        推送失败下一拍会重试。"""
        t = now()
        if src == "health":
            if label in self.health_on:
                return False
        elif t - self.last_alarm.get(label, 0) < self.a.cooldown:
            return False
        body = {"label": label, "cn": cn, "lvl": int(lvl), "src": src,
                "tid": tid, "score": float(score), "note": note[:180],
                "m": metrics or {}}
        try:
            code, raw = self.cloud.post("/api/alarm", body, timeout=8)
        except Exception as e:                                # noqa: BLE001
            log("alarm push failed: %s" % e)
            return False
        if code != 200:
            log("alarm push HTTP %d" % code)
            return False
        self.last_alarm[label] = t
        aid = None
        try:
            aid = (json.loads(raw.decode("utf-8")) or {}).get("id")
        except Exception:                                     # noqa: BLE001
            pass
        log("alarm → cloud: %s %s (%s)" % (label, cn, aid))
        if not (aid and with_img):
            return True
        jpg = None
        try:
            q = "/snapshot.jpg?w=%d&q=%d&full=0" % (self.a.snap_width, self.a.snap_quality)
            jpg = self.local.get_bytes(q, timeout=6)
        except Exception:                                     # noqa: BLE001
            jpg = None
        if not jpg:
            return True
        if len(jpg) > 60 * 1024:
            jpg = shrink_jpeg(jpg, self.a.snap_width, self.a.snap_quality)
        if not jpg or len(jpg) > 400 * 1024 or not jpg.startswith(b"\xff\xd8"):
            return True
        try:
            self.cloud.post_bytes("/api/alarm/%s/snap" % aid, jpg, "image/jpeg",
                                  timeout=10)
            log("  shot %d KB" % (len(jpg) // 1024))
        except Exception as e:                                # noqa: BLE001
            log("  shot failed: %s" % e)
        # 事件视频：缓存里取前 5s，再录 5s，合成 mp4 上传
        self.clips.trigger(aid, t)
        return True

    # ---------------- 指令 ----------------
    def exec_cmd(self, c):
        op = str(c.get("op") or "")
        p = c.get("p") or {}
        board = self.local
        try:
            if op in ("params", "fpga", "ai"):
                code, raw = board.post("/api/" + op, p, gz=False, timeout=15)
                if code == 200:
                    msg = ""
                    try:
                        j = json.loads(raw.decode("utf-8"))
                        msg = str(j.get("message") or "")
                        if j.get("ok") is False:
                            return False, msg or "板端返回失败"
                    except Exception:                         # noqa: BLE001
                        pass
                    return True, msg
                return False, "HTTP %d" % code
            if op == "mode":
                code, raw = board.post("/api/mode", p, gz=False, timeout=90)
                ok = code == 200
                msg = ""
                try:
                    j = json.loads(raw.decode("utf-8"))
                    msg = str(j.get("message") or j.get("error") or j.get("note") or "")
                except Exception:                             # noqa: BLE001
                    pass
                return ok, msg[:200]
            if op == "jpeg":
                code, _ = board.post("/api/jpeg", {"hw": bool(p.get("hw"))}, gz=False, timeout=8)
                return code == 200, "硬件 JPEG %s" % ("开" if p.get("hw") else "关")
            if op == "snap":
                w = int(p.get("w") or 800)
                jpg = board.get_bytes("/snapshot.jpg?w=%d&q=55&full=0" % w, timeout=8)
                if not jpg:
                    return False, "本机抓拍失败"
                if len(jpg) > 120 * 1024:
                    jpg = shrink_jpeg(jpg, w, 55)
                code, _ = self.cloud.post_bytes("/api/live", jpg, "image/jpeg", timeout=10)
                return code == 200, "已上传 %dKB" % (len(jpg) // 1024)
            if op == "preset":
                return self.exec_cmd({"op": "fpga", "p": p})
            if op == "ppoff":
                return self.exec_cmd({"op": "fpga", "p": {"PP_EN": 0, "BASIC_EN": 0}})
            if op == "reboot":
                # 板上 9012 目前没有 reboot 端点；保留占位，避免误重启
                return False, "板端未提供 reboot 接口"
            return False, "未知指令 %s" % op
        except Exception as e:                                # noqa: BLE001
            return False, "%s: %s" % (type(e).__name__, e)

    def cmd_loop(self):
        since = 0
        while not self.stop.is_set():
            try:
                r = self.cloud.get_json("/api/commands?since=%d&wait=20" % since,
                                        timeout=40)
                if not isinstance(r, dict):
                    time.sleep(3)
                    continue
                cmds = r.get("cmds") or []
                for c in cmds:
                    seq = int(c.get("seq") or 0)
                    since = max(since, seq)
                    log("cmd #%d %s %s" % (seq, c.get("op"), json.dumps(c.get("p"),
                                                                        ensure_ascii=False)[:120]))
                    ok, msg = self.exec_cmd(c)
                    try:
                        self.cloud.post("/api/result",
                                        {"seq": seq, "op": c.get("op"),
                                         "ok": bool(ok), "msg": msg[:200]}, timeout=8)
                    except Exception as e:                    # noqa: BLE001
                        log("result post failed: %s" % e)
                if not cmds and r.get("seq") is not None:
                    since = max(since, int(r["seq"]))
            except Exception as e:                            # noqa: BLE001
                log("cmd poll failed: %s" % e)
                time.sleep(3)

    # ---------------- 主循环 ----------------
    def node_info(self):
        return {"id": self.a.node, "name": self.a.name, "ver": self.a.fw,
                "ip": self.node_ip or "", "mode": self.mode_str()}

    def mode_str(self):
        cam = ((self.fpga_cache or {}).get("phys") or {})
        rm = cam.get("res_mode")
        fps = cam.get("fps")
        if rm is None:
            return ""
        base = "4K" if rm in (1, 2) else "1080p"
        return base + (str(int(fps)) if fps else "")

    def run_once(self):
        tel, st, ai = self.collect()
        body = {"node": self.node_info(), "tel": tel}
        code, raw = self.cloud.post("/api/ingest", body, timeout=8)
        self.seq += 1
        if code != 200:
            raise IOError("ingest HTTP %d" % code)
        # 心跳送达才清“已恢复”队列，否则下一拍还带着，避免云端错过恢复事件
        self.recovered = []
        return tel

    def seed_health(self):
        """接手云端尚未恢复的健康项（label 列表）。
        代理重启后进程内 health_on 是空的，不接手的话：
          * 同一个持续异常会重新报一次（重复）；
          * 异常恢复时没有对象可“关回合”，云端永远收不到 health.ok。
        拿不到（网络/老服务端）就当没有，退化成“云端合并”。
        """
        d = self.cloud.get_json("/api/health_open", timeout=6) or {}
        labels = [str(x) for x in (d.get("labels") or [])][:8]
        if not labels:
            return
        t = now()
        for lb in labels:
            self.health_on[lb] = t
        log("接手未恢复的健康告警: %s" % ",".join(labels))

    def run(self):
        log("%s %s → %s (local %s, interval %ss)"
            % (APP, VER, self.a.server, self.a.local, self.a.interval))
        threading.Thread(target=self.cmd_loop, daemon=True, name="cmd").start()
        self.seed_health()
        if getattr(self.a, "clip_on", True):
            self.clips.start()
        while True:
            t0 = now()
            try:
                tel = self.run_once()
                self.fail_cloud = 0
                if self.ticks % 6 == 1:
                    log("hb fps=%s cpu=%s temp=%s disk=%s alarms=%d/%d"
                        % (tel["link"].get("fps"), tel["sys"].get("cpu"),
                           tel["sys"].get("temp"), tel["sys"].get("disk"),
                           len(tel["health"]["crit"]), len(tel["health"]["warn"])))
            except Exception as e:                            # noqa: BLE001
                self.fail_cloud += 1
                log("ingest failed (%d): %s" % (self.fail_cloud, e))
            time.sleep(max(1.0, self.a.interval - (now() - t0)))


def selftest_clip(ag, secs):
    """自检：录 secs 秒 → 合一个 clip_pre+clip_post 的片段 → 打印大小/时长。"""
    ag.clips.start()
    log("自检：录 %.0fs 后合成片段…" % secs)
    time.sleep(secs)
    t = now()
    time.sleep(float(ag.a.clip_post))
    out = os.path.join(ag.a.clip_dir, "selftest_%d.mp4" % int(time.time()))
    d = ag.clips.make_clip(t, out)
    if not d:
        log("自检失败：合成不出 mp4")
        return 3
    size = os.path.getsize(out)
    log("自检 OK: %s  时长 %.1fs  大小 %.1f KB  (%.0f kbps)"
        % (out, d, size / 1024.0, size * 8 / max(0.1, d) / 1000.0))
    if getattr(ag.a, "selftest_upload", False):
        code, raw = ag.cloud.post("/api/alarm", {
            "label": "clip_test", "cn": "视频链路自检", "lvl": 1, "src": "test",
            "note": "selftest %.1fs" % d}, timeout=8)
        aid = None
        try:
            aid = (json.loads(raw.decode("utf-8")) or {}).get("id")
        except Exception:                                     # noqa: BLE001
            aid = None
        log("自检：建测试报警 HTTP %s id=%s" % (code, aid))
        if aid and ag.clips.send(aid, out, d):
            log("自检：视频已上传 %s" % aid)
        else:
            log("自检：视频上传失败")
            return 4
    return 0


def main():
    ap = argparse.ArgumentParser(description="CSI2RK cloud agent (board side)")
    ap.add_argument("--server", default=os.environ.get("CSI_SERVER", "https://<SERVER_DOMAIN>"))
    ap.add_argument("--token", default=os.environ.get("CSI_TOKEN", ""))
    ap.add_argument("--token-file", default="/root/rk/cloud/token")
    ap.add_argument("--local", default="http://127.0.0.1:9012")
    ap.add_argument("--device", default="/dev/video22")
    ap.add_argument("--node", default=socket.gethostname())
    ap.add_argument("--name", default="AFC03 IMX415")
    ap.add_argument("--fw", default="V45")
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--cooldown", type=float, default=15.0)
    ap.add_argument("--snap-width", type=int, default=640)
    ap.add_argument("--snap-quality", type=int, default=55)
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("--once", action="store_true", help="只发一次心跳（调试）")
    # ---- 事件视频（前 5s 环形缓存 + 后 5s，mp4 上传）----
    ap.add_argument("--ring-dir", default="/mnt/sd/csi_ring",
                    help="环形缓存目录（SD 卡；放 /dev/shm 可省卡寿命）")
    ap.add_argument("--clip-dir", default="/mnt/sd/csi_clips",
                    help="待上传视频目录（滚动上限见 --clip-total-mb）")
    ap.add_argument("--ring-fps", type=int, default=8)
    ap.add_argument("--clip-pre", type=float, default=5.0)
    ap.add_argument("--clip-post", type=float, default=5.0)
    ap.add_argument("--clip-width", type=int, default=640)
    ap.add_argument("--clip-quality", type=int, default=50)
    ap.add_argument("--clip-bps", type=int, default=450000)
    ap.add_argument("--clip-total-mb", type=int, default=1024)
    ap.add_argument("--no-clip", action="store_true", help="关闭事件视频")
    ap.add_argument("--gst", default="gst-launch-1.0")
    ap.add_argument("--selftest-clip", type=float, default=0,
                    help="录 N 秒后合一个片段到 --clip-dir 并打印大小（不上传）")
    ap.add_argument("--selftest-upload", action="store_true",
                    help="配合 --selftest-clip：建一条测试报警并把视频传上去")
    a = ap.parse_args()

    if not a.token and a.token_file and os.path.exists(a.token_file):
        try:
            with open(a.token_file, "r") as f:
                a.token = f.read().strip()
        except Exception:                                     # noqa: BLE001
            pass
    if not a.token:
        sys.stderr.write("缺少 --token 或 --token-file\n")
        return 2
    a.snap_width = max(320, min(1280, a.snap_width))
    a.snap_quality = max(30, min(80, a.snap_quality))
    a.clip_on = not a.no_clip
    a.clip_pre = max(0.0, min(15.0, a.clip_pre))
    a.clip_post = max(0.0, min(15.0, a.clip_post))
    a.ring_fps = max(2, min(15, a.ring_fps))
    a.clip_width = max(320, min(1280, a.clip_width))

    ag = Agent(a)
    if a.selftest_clip:
        return selftest_clip(ag, a.selftest_clip)
    if a.once:
        tel = ag.run_once()
        print(json.dumps(tel, ensure_ascii=False, indent=2))
        return 0
    try:
        ag.run()
    except KeyboardInterrupt:
        ag.stop.set()
        return 0


if __name__ == "__main__":
    sys.exit(main())
