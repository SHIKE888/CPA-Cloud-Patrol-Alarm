#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CSI2RK 云端看板 —— 服务端（单文件 / 仅标准库 / 无数据库）

目标机是低配 VPS（1~2 核 / 1.6GB RAM / 40GB 盘），所以：
  * 依赖：只用 Python 3.8+ 标准库，不建 venv、不 pip install、不装框架
  * 存储：data/state.json（<256KB）+ data/shots/*.jpg（条数 + 总字节双上限滚动删）
  * 算力：服务端完全不碰图像，缩略图由板端生成
  * 网络：心跳 3s；指令走长轮询（空闲 25s 一个空请求）；图片只在报警时上传

拓扑：
    [浏览器] --HTTPS--> nginx --/api/--> 本服务(127.0.0.1:9080)
                                            ^
    [RK3576 板] --cloud_agent.py 长轮询---┘   （板上没有公网 IP，只能板子主动连出来）

用法：
    python3 server.py --demo                 # 本机自测（假数据，不连板子）
    python3 server.py --config /etc/csi-dashboard.json
"""
from __future__ import print_function

import argparse
import base64
import gzip
import hashlib
import hmac
import importlib.util
import json
import os
import re
import sys
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

APP = "csi-dashboard"
VER = "1.0"
ROOT = os.path.dirname(os.path.abspath(__file__))

# ----------------------------------------------------------------------------
# 默认配置
# ----------------------------------------------------------------------------
DEF = {
    "host": "127.0.0.1",
    "port": 9080,
    "data_dir": "data",              # 相对 server.py 所在目录
    "static_dir": "static",
    "token": "",                     # 板端上行令牌（必填）
    "ui_user": "",                   # 看板 Basic 认证（可选；留空=公开）
    "ui_pass": "",
    "offline_sec": 30,               # 超过这么久没心跳 = 离线
    "alarm_hold_sec": 180,           # 未确认报警让灯保持红色的时长
    "dedupe_sec": 6,                 # 同标签去抖窗口
    "health_hold_sec": 3600,         # 系统异常（src=health）同一回合最长合并窗口
    "max_alarms": 500,               # 内存/DB 里保留的报警条数
    "max_rate": 20,                  # 每分钟最多接受多少条报警（防刷）
    "max_shots": 100,                # 图片条数上限
    "max_shot_mb": 20,               # 图片目录总字节上限
    "max_alarm_kb": 600,             # 单张报警图上限
    "max_clip_mb": 8,                # 单个事件视频上限
    "max_clip_total_mb": 1024,       # 视频目录总上限（滚动删除，默认 1GB）
    "demo": False,
    "allow_test": False,             # 允许看板触发“测试报警”
    "allow_reboot": False,           # 允许远程重启板卡（默认关）
}
CFG = dict(DEF)

PARAM_RANGE = {                      # 与板端 mipi_webstream.py 一致
    "brightness": (-100, 100), "contrast": (0.2, 3.0),
    "saturation": (0.0, 3.0), "hue": (-180, 180), "gamma": (0.2, 3.0),
    "mirror": (0, 1), "flipv": (0, 1), "rotate": (0, 270),
    "scale": (0.25, 1.5), "quality": (30, 95), "fps": (1, 120),
}
FP_RANGE = {                         # 板端 /api/fpga 的物理量
    "cam_exp_ms": (0.05, 40.0), "cam_gain_db": (0.0, 30.0),
    "ev": (-3, 3), "wb_r_pct": (0, 200), "wb_b_pct": (0, 200),
    "roi_pct": (25, 100), "fps": (1, 120), "res_mode": (0, 2),
}
REG_RANGE = {                        # 允许直写的寄存器（白名单）
    "PP_EN": (0, 1), "ADV_MODE": (0, 8),
    "ADV_SOBEL_SH": (1, 16), "ADV_THRESH": (0, 255), "ADV_MORPH_SEL": (0, 1),
    "ADV_MORPH_TH": (0, 255), "ADV_LAP_SH": (1, 16), "ADV_PREW_SH": (1, 16),
    "ADV_EMBOSS_GAIN": (0, 8), "ADV_EMBOSS_BIAS": (0, 255),
    "ADV_SHARP_GAIN": (1, 16), "BASIC_EN": (0, 31), "BASIC_GRAY": (0, 1),
    "BASIC_GAUSS": (0, 8), "BASIC_HE": (0, 255), "BASIC_CONTRAST": (0, 8),
    "BASIC_KER": (0, 2), "BASIC_HE_CLIP": (0, 255), "BASIC_HE_TEMP": (0, 8),
    "BASIC_LINEFIX": (0, 1),
}
PRESETS = {"off", "orig", "sobel", "thresh", "morph", "median", "lap",
           "emboss", "prewitt", "sharpen", "gray", "gauss", "he",
           "gray_gauss", "gauss_he", "negative"}
AI_NUM = {"ai_fps": (0.5, 60), "det_conf": (0.05, 0.95),
          "nms_thres": (0.05, 0.95), "kpt_conf": (0.0, 0.95),
          "kpt_margin": (-1.0, 2.0), "kpt_scale_max": (0.0, 5.0),
          "roi_expand": (1.0, 2.0), "det_interval": (1, 10),
          "pose_budget": (0, 16), "max_persons": (1, 16)}
AI_BOOL = {"enabled", "show_skeleton", "show_score", "show_label",
           "show_hud", "skeleton_only", "copy_frame", "spread_pose"}
AI_TUNE = {"fall": (0.3, 1.0), "run": (0.5, 2.5),
           "swing": (0.3, 2.5), "throw": (0.3, 2.5)}
MODES = {"1080p60", "1080p30", "1080p15", "4k25", "4k15", "4k10", "4k30", "720p90"}

# 报警动作的正式表述（板端 label → 平台显示名）
# 板端模型标签不变（它还要画在本地画面上），只改云端展示与历史记录。
FORMAL_CN = {
    "fall": "跌倒事件", "lying": "倒地未起事件", "climb": "攀爬越界事件",
    "fight": "肢体冲突事件", "intrude": "越界入侵事件", "run": "奔跑行为",
    "handup": "举手求助事件", "squat": "下蹲行为", "swing": "挥击行为",
    "throw": "投掷行为", "photo": "持机拍摄行为",
}


def formal_cn(label, cn=None):
    lab = str(label or "").strip().lower()
    if lab in FORMAL_CN:
        return FORMAL_CN[lab]
    return str(cn or label or "报警事件")[:24]

# 预留扩展点：真实实现放在 ext/<name>.py，暴露 INFO 与 handle(payload)
EXT_RESERVED = [
    {"name": "gimbal", "title": "云台控制",
     "desc": "yaw/pitch 速度、角度、自稳、回零（板端 QGimbal 串口已具备，缺 HTTP 封装）"},
    {"name": "record", "title": "录像 / 回放",
     "desc": "报警前后 10s 短片；受上行带宽限制，默认只保留抓拍"},
    {"name": "webhook", "title": "告警外推",
     "desc": "钉钉 / 企业微信 / 短信；本机可只转发一行 JSON，不做重试队列"},
    {"name": "zone", "title": "警戒区 / 多目标规则",
     "desc": "归一化多边形 zone 已能透传，缺少前端绘制与多摄像头管理"},
    {"name": "ota", "title": "远程升级",
     "desc": "拉取 FPGA bit / boot.img / 脚本；需签名与回滚，暂不开放"},
]

# ----------------------------------------------------------------------------
# 小工具
# ----------------------------------------------------------------------------


def now():
    return time.time()


def log(msg):
    sys.stderr.write("[%s] %s\n" % (time.strftime("%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()


def _num(v, lo, hi):
    f = float(v)
    if f != f:                                  # NaN
        raise ValueError("nan")
    return min(max(f, lo), hi)


def _int(v, lo, hi):
    return int(round(_num(v, lo, hi)))


def fmt_age(sec):
    sec = int(max(0, sec))
    if sec < 60:
        return "%d 秒" % sec
    if sec < 3600:
        return "%d 分 %d 秒" % (sec // 60, sec % 60)
    if sec < 86400:
        return "%d 小时 %d 分" % (sec // 3600, (sec % 3600) // 60)
    return "%d 天 %d 小时" % (sec // 86400, (sec % 86400) // 3600)


def _ui_sid():
    """由密码派生的会话值：改密码即全部失效，服务端无需存 session。"""
    return hmac.new((CFG["ui_pass"] or "").encode("utf-8"),
                    b"csi-dashboard-ui-v1", hashlib.sha256).hexdigest()


# ----------------------------------------------------------------------------
# 状态（内存 + 一个 JSON 文件）
# ----------------------------------------------------------------------------
LOCK = threading.Condition()
S = {
    "v": 1,
    "node": {},
    "hb": {"ts": 0, "seq": 0},
    "tel": {},
    "alarms": [],
    "pending": [],
    "results": [],
    "seq": 0,
    "next_id": 0,
    "live": {"rev": 0, "ts": 0},
    "stats": {"rx": 0, "alarms": 0, "dropped": 0},
}
STARTED = now()
_last_save = 0.0


def state_path():
    return os.path.join(CFG["data_dir"], "state.json")


def shots_dir():
    return os.path.join(CFG["data_dir"], "shots")


def clips_dir():
    return os.path.join(CFG["data_dir"], "clips")


def clip_path(aid):
    return os.path.join(clips_dir(), aid + ".mp4")


def db_path():
    return os.path.join(CFG["data_dir"], "dash.db")


def shot_path(aid):
    return os.path.join(shots_dir(), aid + ".jpg")


def live_path():
    return os.path.join(CFG["data_dir"], "live.jpg")


def ensure_dirs():
    for d in (CFG["data_dir"], shots_dir(), clips_dir()):
        try:
            os.makedirs(d)
        except OSError:
            pass


# ----------------------------------------------------------------------------
# SQLite：报警/视频的正式存储（state.json 只留遥测/指令这类瞬时数据）
# ----------------------------------------------------------------------------
ALARM_COLS = ("id", "ts", "lvl", "label", "cn", "en", "tid", "score", "src",
              "note", "m", "img", "ack", "ack_ts", "n", "last_ts", "last_note",
              "recovered", "clip", "clip_bytes", "clip_sec")

_DDL = """
CREATE TABLE IF NOT EXISTS alarms(
  id TEXT PRIMARY KEY, ts REAL NOT NULL, lvl INTEGER, label TEXT, cn TEXT, en TEXT,
  tid INTEGER, score REAL, src TEXT, note TEXT, m TEXT,
  img INTEGER DEFAULT 0, ack INTEGER DEFAULT 0, ack_ts REAL, n INTEGER DEFAULT 1,
  last_ts REAL, last_note TEXT, recovered REAL,
  clip INTEGER DEFAULT 0, clip_bytes INTEGER DEFAULT 0, clip_sec REAL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS i_alarms_ts ON alarms(ts DESC);
CREATE INDEX IF NOT EXISTS i_alarms_label ON alarms(label, ts DESC);
CREATE TABLE IF NOT EXISTS clips(
  alarm_id TEXT PRIMARY KEY, ts REAL, sec REAL, bytes INTEGER, path TEXT
);
CREATE INDEX IF NOT EXISTS i_clips_ts ON clips(ts);
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
"""
_DB = None


def db():
    global _DB
    if _DB is None:
        _DB = sqlite3.connect(db_path(), check_same_thread=False)
        _DB.row_factory = sqlite3.Row
        _DB.execute("PRAGMA journal_mode=WAL")
        _DB.execute("PRAGMA synchronous=NORMAL")
        _DB.executescript(_DDL)
        _DB.commit()
    return _DB


def db_put_alarm(a):
    """整行 upsert（必须在 LOCK 内）。"""
    row = []
    for k in ALARM_COLS:
        v = a.get(k)
        if k == "m":
            v = json.dumps(v or {}, ensure_ascii=False, separators=(",", ":"))
        elif k in ("img", "ack"):
            v = 1 if v else 0
        elif k == "cn":
            v = formal_cn(a.get("label"), v)
        row.append(v)
    try:
        db().execute("INSERT OR REPLACE INTO alarms(%s) VALUES(%s)"
                     % (",".join(ALARM_COLS), ",".join("?" * len(ALARM_COLS))), row)
        db().commit()
    except sqlite3.Error as e:
        log("db alarm write failed: %s" % e)


def db_del_alarm(aid):
    try:
        db().execute("DELETE FROM alarms WHERE id=?", (aid,))
        db().execute("DELETE FROM clips WHERE alarm_id=?", (aid,))
        db().commit()
    except sqlite3.Error as e:
        log("db alarm delete failed: %s" % e)


def db_load_alarms(limit):
    out = []
    try:
        cur = db().execute("SELECT * FROM alarms ORDER BY ts DESC LIMIT ?", (limit,))
        rows = list(cur)
    except sqlite3.Error as e:
        log("db alarm read failed: %s" % e)
        return out
    for r in rows:
        a = dict(r)
        a["img"] = bool(a.get("img"))
        a["ack"] = bool(a.get("ack"))
        try:
            a["m"] = json.loads(a.get("m") or "{}")
        except ValueError:
            a["m"] = {}
        a["cn"] = formal_cn(a.get("label"), a.get("cn"))
        if not a.get("clip"):
            a.pop("clip", None)
            a.pop("clip_bytes", None)
            a.pop("clip_sec", None)
        for k in ("last_ts", "last_note", "recovered", "ack_ts"):
            if a.get(k) is None:
                a.pop(k, None)
        out.append(a)
    return out


def load_state():
    raw = {}
    try:
        with open(state_path(), "r", encoding="utf-8") as f:
            raw = json.load(f)
    except Exception:                                         # noqa: BLE001
        raw = {}
    if not isinstance(raw, dict):
        raw = {}
    json_alarms = raw.get("alarms") or []
    raw["alarms"] = []
    for k in S:
        if k in raw and type(raw[k]) is type(S[k]):
            S[k] = raw[k]
    # 报警/视频从 SQLite 读；若 DB 是空的而旧 state.json 里有，就迁移一次
    rows = db_load_alarms(CFG["max_alarms"])
    if not rows and json_alarms:
        for a in reversed(json_alarms):            # 旧→新写入，保持 ts 顺序
            if isinstance(a, dict) and a.get("id"):
                a["cn"] = formal_cn(a.get("label"), a.get("cn"))
                db_put_alarm(a)
        rows = db_load_alarms(CFG["max_alarms"])
        log("migrated %d alarms: state.json -> SQLite" % len(json_alarms))
    S["alarms"] = rows
    log("state loaded: %d alarms (sqlite), %d pending"
        % (len(S["alarms"]), len(S["pending"])))


def _save_locked(force=False):
    """必须在持有 LOCK 时调用。报警/视频在 SQLite，这里只落遥测/指令这类瞬时数据。"""
    global _last_save
    if not force and now() - _last_save < 10.0:
        return
    try:
        snap = dict(S)
        snap["alarms"] = []                     # 报警不重复存 JSON
        tmp = state_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(snap, f, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, state_path())
        _last_save = now()
    except Exception as e:                                    # noqa: BLE001
        log("save failed: %s: %s" % (type(e).__name__, e))


def save(force=False):
    with LOCK:
        _save_locked(force)


def _prune_locked():
    """图片按条数 + 总字节滚动删除；返回删除数量。"""
    d = shots_dir()
    try:
        names = os.listdir(d)
    except OSError:
        return 0
    files = []
    total = 0
    for fn in names:
        if not fn.endswith(".jpg"):
            continue
        p = os.path.join(d, fn)
        try:
            st = os.stat(p)
        except OSError:
            continue
        files.append((st.st_mtime, st.st_size, p))
        total += st.st_size
    files.sort()
    maxb = int(CFG["max_shot_mb"] * 1024 * 1024)
    removed = 0
    while files and (len(files) > CFG["max_shots"] or total > maxb):
        _mt, sz, p = files.pop(0)
        try:
            os.remove(p)
            removed += 1
        except OSError:
            pass
        total -= sz
    return removed


def _drop_alarm_locked(idx):
    try:
        a = S["alarms"].pop(idx)
    except IndexError:
        return
    aid = a.get("id", "")
    for p in (shot_path(aid), clip_path(aid)):
        try:
            os.remove(p)
        except OSError:
            pass
    db_del_alarm(aid)


def _mark_health_recovered_locked(labels):
    """把每个 label 最新一条未恢复的健康报警标成已恢复（= 这一回合结束）。

    板端在“异常→正常”时把 label 放进 tel.health.ok，下次同一异常才会重新记一条，
    所以云端不需要猜“还在不在异常”，也不会把两次独立异常并成一条。
    """
    ts = now()
    n = 0
    for lb in list(labels)[:8]:
        lb = str(lb)[:32]
        for a in S["alarms"]:
            if a.get("label") == lb and a.get("src") == "health":
                if not a.get("recovered"):
                    a["recovered"] = ts
                    db_put_alarm(a)
                    n += 1
                break
    return n


def add_alarm(meta):
    """返回 (alarm_dict|None, deduped)。"""
    with LOCK:
        ts = now()
        label = str(meta.get("label") or "alarm")[:32]
        lvl = _int(meta.get("lvl", 2), 1, 3)
        src = str(meta.get("src") or "ai")[:16]
        # 系统异常（health）：磁盘/温度/链路/无帧/FPGA 都是“持续状态”，
        # 一次异常只保留**最早那一条**，恢复前重复上报只累加 n，不新增记录。
        # 板端已改成边沿触发（正常→异常才报），这里兜住代理重启/网络抖动
        # 造成的重复上报：靠板端上报的 tel.health.ok 标记 recovered 来关回合。
        if src == "health":
            for a in S["alarms"]:
                if a.get("label") != label or a.get("src") != "health":
                    continue
                if a.get("recovered"):
                    break                     # 上一回合已结束 → 新异常，走新建
                if ts - float(a.get("ts") or 0) < CFG["health_hold_sec"]:
                    a["n"] = int(a.get("n", 1)) + 1
                    a["last_ts"] = ts
                    if meta.get("note"):
                        a["last_note"] = str(meta.get("note"))[:200]
                    S["stats"]["alarms"] += 1
                    db_put_alarm(a)
                    _save_locked()
                    return a, True
                break
        # 同一标签短时间去抖：合并成一条，n 计数 +1（不额外占图片）
        for a in S["alarms"]:
            if a.get("recovered"):
                continue        # 已恢复的系统异常不再吸收新回合（否则时间戳会被刷新）
            if (a.get("label") == label and not a.get("ack")
                    and ts - float(a.get("ts") or 0) < CFG["dedupe_sec"]):
                a["ts"] = ts
                a["n"] = int(a.get("n", 1)) + 1
                try:
                    a["score"] = round(float(meta.get("score") or a.get("score") or 0), 3)
                except (TypeError, ValueError):
                    pass
                S["stats"]["alarms"] += 1
                db_put_alarm(a)
                _save_locked()
                return a, True
        # 全局限速，防止板端抖动刷爆磁盘
        recent = sum(1 for a in S["alarms"] if ts - float(a.get("ts") or 0) < 60)
        if recent >= CFG["max_rate"]:
            S["stats"]["dropped"] += 1
            _save_locked()
            return None, False
        S["next_id"] = (S["next_id"] + 1) % 1000
        aid = time.strftime("%Y%m%d-%H%M%S", time.localtime(ts)) + "-%03d" % S["next_id"]
        a = {
            "id": aid,
            "ts": ts,
            "lvl": lvl,
            "label": label,
            "cn": formal_cn(label, meta.get("cn")),
            "en": str(meta.get("en") or label)[:24],
            "tid": meta.get("tid"),
            "score": round(float(meta.get("score") or 0), 3),
            "src": str(meta.get("src") or "ai")[:16],
            "note": str(meta.get("note") or "")[:200],
            "m": meta.get("m") if isinstance(meta.get("m"), dict) else {},
            "img": False,
            "ack": False,
            "n": 1,
        }
        S["alarms"].insert(0, a)
        S["stats"]["alarms"] += 1
        db_put_alarm(a)
        while len(S["alarms"]) > CFG["max_alarms"]:
            _drop_alarm_locked(len(S["alarms"]) - 1)
        _prune_locked()
        _save_locked(True)
        log("alarm %s %s (lvl=%d src=%s)" % (aid, label, lvl, a["src"]))
        return a, False


def attach_shot(aid, data):
    if not data or len(data) < 200 or not data.startswith(b"\xff\xd8"):
        return False
    maxb = CFG["max_alarm_kb"] * 1024
    if len(data) > maxb:
        log("shot too big for %s: %d > %d" % (aid, len(data), maxb))
        return False
    ensure_dirs()
    try:
        tmp = shot_path(aid) + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, shot_path(aid))
    except OSError as e:
        log("shot write failed: %s" % e)
        return False
    with LOCK:
        for a in S["alarms"]:
            if a.get("id") == aid:
                a["img"] = True
                db_put_alarm(a)
                break
        _prune_locked()
        _save_locked(True)
    return True


def set_live(data):
    if not data or len(data) < 200 or not data.startswith(b"\xff\xd8"):
        return False
    ensure_dirs()
    try:
        tmp = live_path() + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, live_path())
    except OSError:
        return False
    with LOCK:
        S["live"] = {"rev": int(S["live"].get("rev") or 0) + 1, "ts": now()}
        _save_locked(True)
    return True


def attach_clip(aid, data, sec=0.0):
    """收板端上传的事件视频（mp4）：落盘 + 写库 + 滚动清理。"""
    if not data or len(data) < 1024:
        return False
    if len(data) > CFG["max_clip_mb"] * 1024 * 1024:
        log("clip too big for %s: %d" % (aid, len(data)))
        return False
    if b"ftyp" not in data[:32]:
        log("clip %s: not mp4" % aid)
        return False
    ensure_dirs()
    p = clip_path(aid)
    try:
        tmp = p + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, p)
    except OSError as e:
        log("clip write failed: %s" % e)
        return False
    with LOCK:
        found = None
        for a in S["alarms"]:
            if a.get("id") == aid:
                found = a
                break
        if not found:
            try:
                os.remove(p)
            except OSError:
                pass
            return False
        sec = round(float(sec or 0), 1) or round(len(data) / 45000.0, 1)
        found["clip"] = True
        found["clip_bytes"] = len(data)
        found["clip_sec"] = sec
        db_put_alarm(found)
        try:
            db().execute("INSERT OR REPLACE INTO clips(alarm_id,ts,sec,bytes,path) "
                         "VALUES(?,?,?,?,?)",
                         (aid, float(found.get("ts") or now()), sec, len(data), p))
            db().commit()
        except sqlite3.Error as e:
            log("db clip write failed: %s" % e)
        prune_clips_locked()
        _save_locked()
    log("clip %s: %.1fs %dKB" % (aid, sec, len(data) // 1024))
    return True


def prune_clips_locked():
    """视频滚动上限（默认 1GB）：按 ts 从旧到新删，只清 clip 标记，报警记录保留。"""
    cap = int(CFG["max_clip_total_mb"]) * 1024 * 1024
    try:
        rows = [dict(r) for r in db().execute(
            "SELECT alarm_id, bytes, path FROM clips ORDER BY ts ASC")]
    except sqlite3.Error as e:
        log("clip prune read failed: %s" % e)
        return 0
    total = sum(int(r.get("bytes") or 0) for r in rows)
    removed = 0
    for r in rows:
        if total <= cap:
            break
        try:
            os.remove(r.get("path") or clip_path(r["alarm_id"]))
        except OSError:
            pass
        try:
            db().execute("DELETE FROM clips WHERE alarm_id=?", (r["alarm_id"],))
            db().execute("UPDATE alarms SET clip=0, clip_bytes=0, clip_sec=0 WHERE id=?",
                         (r["alarm_id"],))
        except sqlite3.Error:
            pass
        for a in S["alarms"]:
            if a.get("id") == r["alarm_id"]:
                a.pop("clip", None)
                a.pop("clip_bytes", None)
                a.pop("clip_sec", None)
                break
        total -= int(r.get("bytes") or 0)
        removed += 1
    if removed:
        try:
            db().commit()
        except sqlite3.Error:
            pass
        log("clip prune: removed %d, left %.0fMB" % (removed, total / 1048576.0))
    return removed


def queue_cmd(op, payload):
    with LOCK:
        S["seq"] = int(S.get("seq") or 0) + 1
        c = {"seq": S["seq"], "op": op, "p": payload, "ts": now()}
        S["pending"].append(c)
        S["pending"] = S["pending"][-12:]
        LOCK.notify_all()
        _save_locked(True)
        return c


def wait_cmds(since, wait):
    end = now() + max(0.0, min(wait, 25.0))
    with LOCK:
        while True:
            out = [c for c in S["pending"] if int(c.get("seq") or 0) > since]
            if out:
                return {"ok": True, "seq": S["seq"], "cmds": out}
            left = end - now()
            if left <= 0:
                return {"ok": True, "seq": S["seq"], "cmds": []}
            LOCK.wait(min(left, 5.0))


def take_result(body):
    with LOCK:
        seq = body.get("seq")
        for i, c in enumerate(S["pending"]):
            if c.get("seq") == seq:
                S["pending"].pop(i)
                break
        r = {"seq": seq, "op": str(body.get("op") or "")[:24],
             "ok": bool(body.get("ok")),
             "msg": str(body.get("msg") or "")[:240], "ts": now()}
        S["results"].insert(0, r)
        S["results"] = S["results"][:20]
        _save_locked(True)
        return r


def ack(body):
    with LOCK:
        aid = body.get("id")
        n = 0
        for a in S["alarms"]:
            if (body.get("all") or a.get("id") == aid) and not a.get("ack"):
                a["ack"] = True
                a["ack_ts"] = now()
                db_put_alarm(a)
                n += 1
        _save_locked(True)
        return n


def lamp_state():
    with LOCK:
        tel = S.get("tel") or {}
        hb = S.get("hb") or {}
        hb_ts = float(hb.get("ts") or 0)
        age = now() - hb_ts
        online = bool(hb_ts) and age <= CFG["offline_sec"]
        unacked = [a for a in S["alarms"] if not a.get("ack")]
        newest = unacked[0] if unacked else None
        cur = tel.get("alarm") or {}
        risk = _int(cur.get("risk", 0), 0, 3)
        health = tel.get("health") or {}
        crit = [str(x) for x in (health.get("crit") or [])][:3]
        warn = [str(x) for x in (health.get("warn") or [])][:3]
        st, text = "ok", "正常"
        if not online:
            st, text = "offline", "离线"
        elif ((newest and now() - float(newest.get("ts") or 0) <= CFG["alarm_hold_sec"])
              or risk >= 2 or crit):
            # crit（磁盘/温度/无帧…）持续存在就一直红，不靠报警记录刷新 ts
            st, text = "alarm", "报警"
        elif newest or risk >= 1 or crit or warn:
            st, text = "warn", "预警"
        focus = {}
        cn_cur = formal_cn(cur.get("label"), cur.get("cn"))
        if st == "alarm":
            if newest:
                focus = {"label": newest.get("label"), "cn": newest.get("cn"),
                         "tid": newest.get("tid"), "ts": newest.get("ts"),
                         "src": newest.get("src"), "id": newest.get("id")}
                since = newest.get("ts")
            else:
                focus = {"label": cur.get("label"), "cn": cn_cur or "当前画面",
                         "tid": cur.get("tid"), "ts": now(), "src": "ai"}
                since = now()
        elif st == "warn":
            if newest:
                focus = {"label": newest.get("label"), "cn": newest.get("cn"),
                         "tid": newest.get("tid"), "ts": newest.get("ts"),
                         "src": newest.get("src"), "id": newest.get("id")}
                since = newest.get("ts")
            elif cur:
                focus = {"label": cur.get("label"), "cn": cn_cur or "画面存在风险",
                         "ts": now(), "src": "ai"}
                since = now()
            else:
                focus = {"label": "warn", "cn": (crit or warn or ["设备异常"])[0], "ts": now(), "src": "health"}
                since = now()
        else:
            since = now()
        return {
            "state": st, "text": text,
            "online": online, "age": round(age, 1) if hb_ts else None,
            "hb_ts": hb_ts or None,          # 最近一次心跳的服务器时间（epoch 秒）
            "since": since, "hold": CFG["alarm_hold_sec"],
            "unacked": len(unacked),
            "alarms24": sum(1 for a in S["alarms"] if now() - float(a.get("ts") or 0) < 86400),
            "risk": risk, "focus": focus,
            "notes": crit + warn,
        }


def alarm_public(a, ts=None):
    ts = ts or now()
    return {
        "id": a["id"], "ts": a["ts"], "age": int(ts - a["ts"]),
        "lvl": a.get("lvl", 2), "label": a.get("label"), "cn": a.get("cn"),
        "en": a.get("en"), "tid": a.get("tid"), "score": a.get("score"),
        "src": a.get("src"), "note": a.get("note"), "m": a.get("m") or {},
        "img": bool(a.get("img")), "ack": bool(a.get("ack")), "n": a.get("n", 1),
        "url": "/api/shot/%s.jpg" % a["id"],
        "clip": bool(a.get("clip")),
        "clip_sec": a.get("clip_sec") or 0,
        "clip_kb": int((a.get("clip_bytes") or 0) // 1024),
        "clip_url": ("/api/clip/%s.mp4" % a["id"]) if a.get("clip") else None,
    }


# ----------------------------------------------------------------------------
# 预留扩展点
# ----------------------------------------------------------------------------
_PLUGINS = {}
_PLUGIN_ERR = {}


def load_plugins():
    d = os.path.join(ROOT, "ext")
    if not os.path.isdir(d):
        return
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".py") or fn.startswith("_"):
            continue
        name = fn[:-3]
        try:
            spec = importlib.util.spec_from_file_location("ext_" + name, os.path.join(d, fn))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _PLUGINS[name] = mod
            log("ext loaded: %s" % name)
        except Exception as e:                                # noqa: BLE001
            _PLUGIN_ERR[name] = "%s: %s" % (type(e).__name__, e)
            log("ext failed: %s (%s)" % (name, _PLUGIN_ERR[name]))


def ext_list():
    out = []
    for it in EXT_RESERVED:
        name = it["name"]
        item = dict(it)
        if name in _PLUGINS:
            item["state"] = "ready"
            info = getattr(_PLUGINS[name], "INFO", None)
            if isinstance(info, dict):
                item.update({k: v for k, v in info.items() if k not in ("name",)})
        else:
            item["state"] = "reserved"
            if name in _PLUGIN_ERR:
                item["err"] = _PLUGIN_ERR[name]
        out.append(item)
    return out


# ----------------------------------------------------------------------------
# 指令白名单
# ----------------------------------------------------------------------------
def sanitize(op, p):
    """返回 (payload, err)。板端还会各自夹一次，这里只挡明显非法/越权。"""
    if not isinstance(p, dict):
        p = {}
    if op == "params":
        out = {}
        for k, (lo, hi) in PARAM_RANGE.items():
            if k not in p:
                continue
            try:
                out[k] = (_int(p[k], lo, hi) if k in ("mirror", "flipv", "rotate")
                          else _num(p[k], lo, hi))
            except (TypeError, ValueError):
                return None, "参数非法: %s" % k
        if p.get("reset"):
            return {"reset": True}, None
        return out, None
    if op == "fpga":
        out = {}
        for k, (lo, hi) in FP_RANGE.items():
            if k in p:
                try:
                    out[k] = _num(p[k], lo, hi)
                except (TypeError, ValueError):
                    return None, "参数非法: %s" % k
        for k, (lo, hi) in REG_RANGE.items():
            if k in p:
                try:
                    out[k] = _int(p[k], lo, hi)
                except (TypeError, ValueError):
                    return None, "参数非法: %s" % k
        if "preset" in p:
            if str(p["preset"]) not in PRESETS:
                return None, "未知预设: %s" % p["preset"]
            out["preset"] = str(p["preset"])
        if not out:
            return None, "空指令"
        return out, None
    if op == "ai":
        out = {}
        for k in AI_BOOL:
            if k in p:
                out[k] = bool(p[k])
        for k, (lo, hi) in AI_NUM.items():
            if k in p:
                try:
                    out[k] = (_int(p[k], lo, hi) if k in ("det_interval", "pose_budget", "max_persons")
                              else _num(p[k], lo, hi))
                except (TypeError, ValueError):
                    return None, "参数非法: %s" % k
        if p.get("source") in ("raw", "ai", "detect"):
            out["source"] = p["source"]
        if p.get("preset"):
            out["preset"] = str(p["preset"])[:32]
        if isinstance(p.get("tune"), dict):
            t = {}
            for k, (lo, hi) in AI_TUNE.items():
                if k in p["tune"]:
                    try:
                        t[k] = _num(p["tune"][k], lo, hi)
                    except (TypeError, ValueError):
                        pass
            if t:
                out["tune"] = t
        if isinstance(p.get("zone"), list):
            z = []
            for pt in p["zone"][:16]:
                try:
                    z.append([round(_num(pt[0], 0, 1), 3), round(_num(pt[1], 0, 1), 3)])
                except Exception:                             # noqa: BLE001
                    return None, "zone 点非法"
            out["zone"] = z
        if not out:
            return None, "空指令"
        return out, None
    if op == "mode":
        mid = str(p.get("id") or "")
        if mid not in MODES:
            return None, "未知模式: %s" % mid
        return {"id": mid}, None
    if op == "jpeg":
        return {"hw": bool(p.get("hw"))}, None
    if op == "snap":
        return {"w": 800}, None
    if op in ("ppoff", "preset"):
        return dict(p or {}), None
    if op == "reboot":
        if not CFG["allow_reboot"]:
            return None, "远程重启已禁用（服务端 allow_reboot=false）"
        return {}, None
    return None, "未知指令: %s" % op


# ----------------------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------------------
_STATIC_CACHE = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "csi-dashboard/" + VER

    # ---------------- 基础 ----------------
    def log_message(self, fmt, *a):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8",
              cache="no-store", extra=None, gz=True):
        if isinstance(body, str):
            body = body.encode("utf-8")
        hdrs = {"Content-Type": ctype, "Cache-Control": cache}
        if extra:
            hdrs.update(extra)
        if (gz and len(body) > 700
                and "gzip" in (self.headers.get("Accept-Encoding") or "")):
            body = gzip.compress(body, 5)
            hdrs["Content-Encoding"] = "gzip"
        self.send_response(code)
        for k, v in hdrs.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj, code=200, extra=None):
        self._send(code, json.dumps(obj, ensure_ascii=False, separators=(",", ":")),
                   extra=extra)

    def _err(self, code, msg):
        self._json({"ok": False, "error": msg}, code)

    def _body(self, limit=None):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n < 0:
            n = 0
        cap = limit or (4 * 1024 * 1024)
        if n > cap:
            return None
        raw = self.rfile.read(n) if n else b""
        if (self.headers.get("Content-Encoding") or "") == "gzip" and raw:
            try:
                raw = gzip.decompress(raw)
            except OSError:
                return None
        return raw

    def _json_body(self, limit=None):
        raw = self._body(limit)
        if not raw:
            return {}
        try:
            obj = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None
        return obj if isinstance(obj, dict) else None

    def _auth_board(self):
        tok = self.headers.get("X-Token") or ""
        want = CFG["token"] or ""
        return bool(want) and hmac.compare_digest(tok, want)

    def _auth_ui(self):
        """看板认证：Cookie 会话（网页）> X-UI-Pass（脚本）> Basic（curl -u）。

        ⚠ 不要给 401 加 WWW-Authenticate：Chrome/Edge 对 fetch 的 Basic 弹窗会
          反复重试，最终报 net::ERR_TOO_MANY_RETRIES（2026-10-20 实际踩到）。
        """
        if not CFG["ui_pass"]:
            return True
        want = _ui_sid()
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "cd_sid" and v and hmac.compare_digest(v, want):
                return True
        if hmac.compare_digest(self.headers.get("X-UI-Pass") or "", CFG["ui_pass"]):
            return True
        h = self.headers.get("Authorization") or ""
        if h.startswith("Basic "):
            try:
                raw = base64.b64decode(h[6:]).decode("utf-8")
                user, _, pw = raw.partition(":")
            except Exception:                                 # noqa: BLE001
                return False
            return (hmac.compare_digest(user, CFG["ui_user"] or "")
                    and hmac.compare_digest(pw, CFG["ui_pass"]))
        return False

    def _need_ui(self):
        if self._auth_ui():
            return True
        self._json({"ok": False, "login": True, "error": "需要登录"}, 401)
        return False

    def _need_board(self):
        if self._auth_board():
            return True
        self._err(401, "bad token")
        return False

    # ---------------- GET ----------------
    def do_GET(self):
        u = urlparse(self.path)
        path = u.path
        qs = parse_qs(u.query)
        try:
            if path in ("/", "/index.html"):
                return self._static("index.html")
            if path == "/favicon.ico":
                return self._send(204, b"", "image/x-icon")
            if path == "/api/ping":
                return self._json({"ok": 1, "app": APP, "ver": VER})
            if path == "/api/state":
                if not self._need_ui():
                    return
                n = _int((qs.get("n") or ["6"])[0], 1, 50)
                with LOCK:
                    alarms = [alarm_public(a) for a in S["alarms"][:n]]
                    out = {
                        "ok": True, "t": now(), "ver": VER,
                        "node": S["node"], "tel": S["tel"],
                        "lamp": lamp_state(),
                        "alarms": alarms,
                        "unacked": sum(1 for a in S["alarms"] if not a.get("ack")),
                        "cmds": S["results"][:3],
                        "live": S["live"],
                        "stats": {"alarms": S["stats"]["alarms"],
                                  "dropped": S["stats"]["dropped"],
                                  "uptime": int(now() - STARTED)},
                        "cfg": {"poll": 5, "allow_test": bool(CFG["demo"] or CFG["allow_test"]),
                                "allow_reboot": bool(CFG["allow_reboot"])},
                    }
                return self._json(out)
            if path == "/api/health_open":
                if not self._need_board():
                    return
                # 给板端代理启动时用：它重启后进程内的 health_on 是空的，
                # 接手这些 label 才能做到“不重复报”且异常恢复时能关掉回合。
                with LOCK:
                    ts = now()
                    out, seen = [], set()
                    for a in S["alarms"]:
                        if a.get("src") != "health":
                            continue
                        lb = a.get("label")
                        if lb in seen:
                            continue
                        seen.add(lb)
                        if (not a.get("recovered")
                                and ts - float(a.get("ts") or 0) <= CFG["health_hold_sec"]):
                            out.append(lb)
                return self._json({"ok": True, "labels": out[:8]})
            if path == "/api/history":
                if not self._need_ui():
                    return
                # 时间范围 + 分页：start/end（epoch 秒）、page、limit、unacked=1
                # 兼容旧用法 before=<ts>（取更早的记录）
                start = float((qs.get("start") or ["0"])[0] or 0)
                end = float((qs.get("end") or ["0"])[0] or 0)
                before = float((qs.get("before") or ["0"])[0] or 0)
                page = _int((qs.get("page") or ["1"])[0], 1, 10000)
                lim = _int((qs.get("limit") or ["20"])[0], 1, 100)
                un = str((qs.get("unacked") or ["0"])[0]).lower() in ("1", "true", "yes")
                with LOCK:
                    rows = []
                    for a in S["alarms"]:
                        ts = float(a.get("ts") or 0)
                        if start and ts < start:
                            continue
                        if end and ts > end:
                            continue
                        if before and ts >= before:
                            continue
                        if un and a.get("ack"):
                            continue
                        rows.append(a)
                    total = len(rows)
                    pages = max(1, (total + lim - 1) // lim)
                    page = min(page, pages)
                    chunk = rows[(page - 1) * lim: page * lim]
                    out = [alarm_public(a) for a in chunk]
                return self._json({"ok": True, "alarms": out,
                                   "total": total, "page": page, "pages": pages})
            if path == "/api/stats":
                if not self._need_ui():
                    return
                with LOCK:
                    t = now()
                    # 24 个整点桶（最早 23 小时前 → 当前小时）
                    h0 = int(t // 3600) * 3600 - 23 * 3600
                    hn = [0] * 24
                    hc = [0] * 24
                    # 最近 7 天（按本地零点对齐）
                    lt = time.localtime(t)
                    mid = int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday,
                                           0, 0, 0, 0, 0, -1)))
                    d0 = mid - 6 * 86400
                    dn = [0] * 7
                    lab = {}
                    for a in S["alarms"]:
                        ts = float(a.get("ts") or 0)
                        i = int((ts - h0) // 3600)
                        if 0 <= i < 24:
                            hn[i] += 1
                            if int(a.get("lvl") or 0) >= 2:
                                hc[i] += 1
                        j = int((ts - d0) // 86400)
                        if 0 <= j < 7:
                            dn[j] += 1
                        if ts >= t - 86400:
                            k = str(a.get("label") or "?")
                            lab[k] = lab.get(k, 0) + 1
                    labels = [{"label": k, "cn": formal_cn(k), "n": v}
                              for k, v in sorted(lab.items(), key=lambda kv: -kv[1])[:6]]
                    out = {"ok": True, "hours": {"t0": h0, "n": hn, "crit": hc},
                           "days": {"t0": d0, "n": dn},
                           "total24": sum(hn), "total7": sum(dn),
                           "labels": labels}
                return self._json(out)
            if path.startswith("/api/shot/"):
                if not self._need_ui():
                    return
                name = path[len("/api/shot/"):]
                if not re.match(r"^[0-9]{8}-[0-9]{6}-[0-9]{3}\.jpg$", name):
                    return self._err(400, "bad name")
                return self._file(os.path.join(shots_dir(), name),
                                  "image/jpeg", "public, max-age=31536000, immutable")
            if path.startswith("/api/clip/"):
                if not self._need_ui():
                    return
                name = path[len("/api/clip/"):]
                m = re.match(r"^([0-9]{8}-[0-9]{6}-[0-9]{3})\.mp4$", name)
                if not m:
                    return self._err(400, "bad name")
                return self._video(clip_path(m.group(1)))
            if path == "/api/live.jpg":
                if not self._need_ui():
                    return
                return self._file(live_path(), "image/jpeg", "no-store")
            if path == "/api/ext":
                if not self._need_ui():
                    return
                return self._json({"ok": True, "modules": ext_list()})
            if path == "/api/commands":
                if not self._need_board():
                    return
                since = _int((qs.get("since") or ["0"])[0], 0, 1 << 40)
                wait = _num((qs.get("wait") or ["0"])[0], 0, 25)
                return self._json(wait_cmds(since, wait))
            return self._err(404, "not found")
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:                                # noqa: BLE001
            log("GET %s failed: %s: %s" % (path, type(e).__name__, e))
            try:
                self._err(500, "server error")
            except Exception:                                 # noqa: BLE001
                pass

    # ---------------- POST ----------------
    def do_POST(self):
        u = urlparse(self.path)
        path = u.path
        try:
            if path == "/api/login":
                body = self._json_body(8 * 1024) or {}
                if (CFG["ui_pass"]
                        and hmac.compare_digest(str(body.get("pass") or ""), CFG["ui_pass"])):
                    secure = "; Secure" if (self.headers.get("X-Forwarded-Proto") == "https") else ""
                    ck = ("cd_sid=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000%s"
                          % (_ui_sid(), secure))
                    return self._json({"ok": True, "user": CFG["ui_user"] or "admin"},
                                      extra={"Set-Cookie": ck})
                return self._json({"ok": False, "error": "密码错误"}, 401)
            if path == "/api/logout":
                return self._json({"ok": True},
                                  extra={"Set-Cookie":
                                         "cd_sid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"})
            if path == "/api/ingest":
                if not self._need_board():
                    return
                body = self._json_body(512 * 1024)
                if body is None:
                    return self._err(400, "bad json")
                with LOCK:
                    node = body.get("node")
                    if isinstance(node, dict) and node:
                        S["node"] = {k: node[k] for k in ("id", "name", "ver", "ip", "mode", "host")
                                     if k in node}
                    tel = body.get("tel")
                    if isinstance(tel, dict):
                        # 板端可能只发部分块（pp 每 3 次心跳才带一次）——
                        # 按一层字典合并，缺的字段保留旧值。
                        old = S.get("tel")
                        if not isinstance(old, dict):
                            old = {}
                        for k, v in tel.items():
                            if isinstance(v, dict) and isinstance(old.get(k), dict):
                                merged = dict(old[k])
                                merged.update(v)
                                old[k] = merged
                            else:
                                old[k] = v
                        S["tel"] = old
                        # 板端“已恢复”的健康项 → 关掉该标签这一回合
                        oks = (tel.get("health") or {}).get("ok") or []
                        if isinstance(oks, list) and oks:
                            _mark_health_recovered_locked(oks)
                    S["hb"] = {"ts": now(), "seq": int(S["hb"].get("seq") or 0) + 1}
                    S["stats"]["rx"] += len(json.dumps(body))
                    _save_locked()
                return self._json({"ok": True, "t": now()})
            if path == "/api/alarm":
                if not self._need_board():
                    return
                body = self._json_body(64 * 1024)
                if body is None:
                    return self._err(400, "bad json")
                a, dedup = add_alarm(body)
                return self._json({"ok": True, "id": a["id"] if a else None,
                                   "dedup": bool(dedup)})
            if path.startswith("/api/alarm/") and path.endswith("/clip"):
                if not self._need_board():
                    return
                aid = path[len("/api/alarm/"):-len("/clip")]
                if not re.match(r"^[0-9]{8}-[0-9]{6}-[0-9]{3}$", aid):
                    return self._err(400, "bad id")
                cap = int(CFG["max_clip_mb"] * 1024 * 1024) + 65536
                data = self._body(cap)
                if data is None:
                    return self._err(413, "too big")
                sec = 0.0
                try:
                    sec = float((parse_qs(u.query).get("sec") or ["0"])[0])
                except (TypeError, ValueError):
                    sec = 0.0
                ok = attach_clip(aid, data, sec)
                return self._json({"ok": ok, "bytes": len(data) if data else 0},
                                  200 if ok else 400)
            if path.startswith("/api/alarm/") and path.endswith("/snap"):
                if not self._need_board():
                    return
                aid = path[len("/api/alarm/"):-len("/snap")]
                if not re.match(r"^[0-9]{8}-[0-9]{6}-[0-9]{3}$", aid):
                    return self._err(400, "bad id")
                data = self._body(CFG["max_alarm_kb"] * 1024 + 1024)
                if data is None:
                    return self._err(413, "too big")
                ok = attach_shot(aid, data)
                return self._json({"ok": ok, "bytes": len(data) if data else 0},
                                  200 if ok else 400)
            if path == "/api/live":
                if not self._need_board():
                    return
                data = self._body(1024 * 1024)
                ok = set_live(data or b"")
                return self._json({"ok": ok, "rev": S["live"].get("rev")},
                                  200 if ok else 400)
            if path == "/api/result":
                if not self._need_board():
                    return
                body = self._json_body(64 * 1024)
                if body is None:
                    return self._err(400, "bad json")
                return self._json({"ok": True, "result": take_result(body)})
            if path == "/api/cmd":
                if not self._need_ui():
                    return
                body = self._json_body(64 * 1024)
                if body is None:
                    return self._err(400, "bad json")
                if not (CFG["token"]):
                    return self._err(503, "服务端未配置 token，板端不会来取指令")
                op = str(body.get("op") or "")
                payload, err = sanitize(op, body.get("p"))
                if err:
                    return self._err(400, err)
                c = queue_cmd(op, payload)
                return self._json({"ok": True, "seq": c["seq"]})
            if path == "/api/ack":
                if not self._need_ui():
                    return
                body = self._json_body(8 * 1024) or {}
                return self._json({"ok": True, "acked": ack(body)})
            if path == "/api/test":
                if not self._need_ui():
                    return
                if not (CFG["demo"] or CFG["allow_test"]):
                    return self._err(403, "测试报警未开启")
                body = self._json_body(8 * 1024) or {}
                label = str(body.get("label") or "fall")[:32]
                a, _ = add_alarm({"label": label, "cn": formal_cn(label),
                                  "lvl": 2, "src": "test", "tid": 1, "score": 0.9})
                return self._json({"ok": bool(a), "id": a["id"] if a else None})
            if path.startswith("/api/ext/"):
                if not self._need_ui():
                    return
                name = path[len("/api/ext/"):]
                mod = _PLUGINS.get(name)
                body = self._json_body(64 * 1024) or {}
                if mod is None or not hasattr(mod, "handle"):
                    return self._json({"ok": False, "reserved": True,
                                       "error": "模块 %s 尚未实现（预留接口）" % name}, 501)
                try:
                    out = mod.handle(body, {"state": S, "queue": queue_cmd, "cfg": CFG})
                except Exception as e:                        # noqa: BLE001
                    return self._err(500, "%s: %s" % (type(e).__name__, e))
                return self._json(out if isinstance(out, dict) else {"ok": True, "data": out})
            return self._err(404, "not found")
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:                                # noqa: BLE001
            log("POST %s failed: %s: %s" % (path, type(e).__name__, e))
            try:
                self._err(500, "server error")
            except Exception:                                 # noqa: BLE001
                pass

    # ---------------- 文件 ----------------
    def _video(self, path):
        """发事件视频，支持 Range（<video> 拖进度条要用）。"""
        try:
            st = os.stat(path)
        except OSError:
            return self._err(404, "not found")
        size = st.st_size
        start, end, code = 0, size - 1, 200
        rng = self.headers.get("Range") or ""
        if rng.startswith("bytes="):
            part = rng[6:].split(",")[0].strip()
            a_, _, b_ = part.partition("-")
            try:
                if a_:
                    start = int(a_)
                    if b_:
                        end = min(int(b_), size - 1)
                elif b_:
                    start = max(0, size - int(b_))
            except ValueError:
                start, end = 0, size - 1
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            code = 206
        n = end - start + 1
        self.send_response(code)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.send_header("Content-Length", str(n))
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                left = n
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _file(self, path, ctype, cache):
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            return self._err(404, "not found")
        return self._send(200, body, ctype, cache, gz=False)

    def _static(self, name):
        path = os.path.join(CFG["static_dir"], name)
        try:
            st = os.stat(path)
        except OSError:
            return self._err(404, "not found")
        etag = '"%x-%x"' % (int(st.st_mtime), st.st_size)
        if (self.headers.get("If-None-Match") or "") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        ck = (path, st.st_mtime, st.st_size)
        hit = _STATIC_CACHE.get(name)
        if not hit or hit[0] != ck:
            with open(path, "rb") as f:
                raw = f.read()
            gzbody = gzip.compress(raw, 6)
            _STATIC_CACHE[name] = (ck, raw, gzbody)
        _ck, raw, gzbody = _STATIC_CACHE[name]
        use_gz = ("gzip" in (self.headers.get("Accept-Encoding") or "")
                  and len(raw) > 700)
        body = gzbody if use_gz else raw
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("ETag", etag)
        if use_gz:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


# ----------------------------------------------------------------------------
# 演示数据
# ----------------------------------------------------------------------------
def seed_demo():
    with LOCK:
        S["node"] = {"id": "afc03", "name": "AFC03 IMX415", "ver": "V45",
                     "ip": "192.168.1.136", "mode": "1080p60"}
        S["hb"] = {"ts": now(), "seq": 1}
        S["tel"] = {
            "link": {"ok": True, "fps": 59.6, "lat": 28.2, "clients": 1},
            "cam": {"cam_exp_ms": 16.6, "cam_exp_max_ms": 16.7,
                    "cam_gain_db": 9.6, "ev": 0, "wb_r_pct": 100,
                    "wb_b_pct": 100, "roi_pct": 100, "res_mode": 0, "base_fps": 60},
            "img": {"brightness": 0, "contrast": 1.0, "saturation": 1.0,
                    "hue": 0, "gamma": 1.0, "scale": 1.0, "quality": 80,
                    "fps": 60, "mirror": 0, "flipv": 0, "rotate": 0},
            "pp": {"PP_EN": 0, "ADV_MODE": 0, "BASIC_EN": 0,
                   "ADV_SOBEL_SH": 8, "ADV_THRESH": 128, "ADV_MORPH_SEL": 0,
                   "ADV_MORPH_TH": 128, "ADV_LAP_SH": 8, "ADV_PREW_SH": 8,
                   "ADV_EMBOSS_GAIN": 4, "ADV_EMBOSS_BIAS": 128, "ADV_SHARP_GAIN": 8,
                   "BASIC_GRAY": 1, "BASIC_GAUSS": 8, "BASIC_HE": 255,
                   "BASIC_CONTRAST": 4, "BASIC_KER": 1, "BASIC_HE_CLIP": 255,
                   "BASIC_HE_TEMP": 2, "BASIC_LINEFIX": 0},
            "ai": {"enabled": True, "active": True, "source": "ai", "fps": 29.8,
                   "persons": 1, "risk": 0, "det_ms": 17.2, "pose_ms": 6.1,
                   "det_conf": 0.35, "tune": {"fall": 1.0, "run": 1.0,
                                              "swing": 1.0, "throw": 1.0}},
            "sys": {"cpu": 48.2, "npu": 33.0, "gpu": 12.0, "mem": 42.0,
                    "temp": 56.0, "disk": 39.0},
            "alarm": {"risk": 0, "label": None, "cn": None},
            "health": {"warn": [], "crit": []},
        }
        if not S["alarms"]:
            add_alarm({"label": "fall", "cn": "跌倒", "lvl": 2, "src": "ai",
                       "tid": 3, "score": 0.91,
                       "m": {"fps": 59.6, "persons": 1}})
        _save_locked(True)


def demo_tick():
    """让演示模式看起来是活的（不改报警）。"""
    with LOCK:
        if not CFG["demo"]:
            return
        S["hb"] = {"ts": now(), "seq": int(S["hb"].get("seq") or 0) + 1}
        tel = S.get("tel") or {}
        sysd = tel.get("sys") or {}
        t = now()
        sysd["cpu"] = round(44 + 6 * abs((t % 10) / 10.0 - 0.5) * 2, 1)
        tel["sys"] = sysd
        tel["link"] = dict(tel.get("link") or {}, fps=round(59.3 + (t % 3) * 0.2, 1))
        S["tel"] = tel


# ----------------------------------------------------------------------------
def load_config():
    ap = argparse.ArgumentParser(description="CSI2RK cloud dashboard")
    ap.add_argument("--config", help="JSON 配置文件")
    ap.add_argument("--host")
    ap.add_argument("--port", type=int)
    ap.add_argument("--data")
    ap.add_argument("--static")
    ap.add_argument("--token")
    ap.add_argument("--ui-user")
    ap.add_argument("--ui-pass")
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--allow-test", action="store_true")
    ap.add_argument("--allow-reboot", action="store_true")
    a = ap.parse_args()

    if a.config:
        try:
            with open(a.config, "r", encoding="utf-8") as f:
                cfg = json.load(f)
            if isinstance(cfg, dict):
                for k, v in cfg.items():
                    if k in CFG:
                        CFG[k] = v
        except Exception as e:                                # noqa: BLE001
            log("config load failed: %s" % e)
    for k, v in (("host", a.host), ("token", a.token), ("ui_user", a.ui_user),
                 ("ui_pass", a.ui_pass), ("data_dir", a.data), ("static_dir", a.static)):
        if v is not None:
            CFG[k] = v
    if a.port is not None:
        CFG["port"] = a.port
    if a.demo:
        CFG["demo"] = True
    if a.allow_test:
        CFG["allow_test"] = True
    if a.allow_reboot:
        CFG["allow_reboot"] = True

    for k in ("data_dir", "static_dir"):
        if not os.path.isabs(CFG[k]):
            CFG[k] = os.path.join(ROOT, CFG[k])
    CFG["port"] = int(os.environ.get("CSI_PORT", CFG["port"]))
    CFG["token"] = os.environ.get("CSI_TOKEN", CFG["token"])
    if not CFG["token"]:
        CFG["token"] = "dev-token-" + str(int(now()))


def main():
    load_config()
    ensure_dirs()
    load_state()
    load_plugins()
    with LOCK:
        _prune_locked()
    if CFG["demo"]:
        seed_demo()

    srv = ThreadingHTTPServer((CFG["host"], CFG["port"]), Handler)
    srv.daemon_threads = True
    log("%s %s on http://%s:%d  data=%s"
        % (APP, VER, CFG["host"], CFG["port"], CFG["data_dir"]))
    log("token=%s  ui_auth=%s  demo=%s"
        % (CFG["token"][:6] + "…", "on" if CFG["ui_pass"] else "off", CFG["demo"]))
    if not CFG["ui_pass"]:
        log("警告：未设置 ui_pass，看板是公开的（建议在 nginx 加 Basic 或设 ui_pass）")

    # 演示模式：后台刷新心跳
    if CFG["demo"]:
        def _tick():
            while True:
                demo_tick()
                time.sleep(3)
        threading.Thread(target=_tick, daemon=True).start()

    try:
        srv.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
