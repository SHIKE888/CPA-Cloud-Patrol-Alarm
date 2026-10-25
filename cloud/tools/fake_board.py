#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fake_board.py —— 在本机冒充 RK3576 的 9012 服务，用来联调 cloud_agent / server。

    python3 fake_board.py --port 9100

支持：
    GET  /api/status /api/sys /api/fpga /api/ai /api/modes /snapshot.jpg
    POST /api/params /api/fpga /api/ai /api/mode /api/jpeg
    GET  /mock/event?label=fall     手动造一条 AI 事件（agent 2~5s 内会上报）
    GET  /mock/fps?x=0              改 fps（0 = 模拟无帧）

它不是产品的一部分，只用于没有板子时验证链路；不依赖第三方库
（PIL/cv2 都没有时用一张内置的纯色小图）。
"""
from __future__ import print_function

import argparse
import base64
import io
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LOCK = threading.Lock()
PARAMS = {"brightness": 0, "contrast": 1.0, "saturation": 1.0, "hue": 0,
          "gamma": 1.0, "mirror": 0, "flipv": 0, "rotate": 0, "scale": 1.0,
          "quality": 80, "fps": 60}
REGS = {"PP_EN": 0, "ADV_MODE": 0, "ADV_SOBEL_SH": 8, "ADV_THRESH": 128,
        "ADV_MORPH_SEL": 0, "ADV_MORPH_TH": 128, "ADV_LAP_SH": 8,
        "ADV_PREW_SH": 8, "ADV_EMBOSS_GAIN": 4, "ADV_EMBOSS_BIAS": 128,
        "ADV_SHARP_GAIN": 8, "BASIC_EN": 0, "BASIC_GRAY": 1, "BASIC_GAUSS": 8,
        "BASIC_HE": 255, "BASIC_CONTRAST": 4, "BASIC_KER": 1,
        "BASIC_HE_CLIP": 255, "BASIC_LINEFIX": 0,
        "CAM_EXP_L": 8, "CAM_EXP_M": 0, "CAM_EXP_H": 0, "CAM_GAIN": 32,
        "EV_BIAS": 8, "WB_R": 128, "WB_B": 128, "FPS_DIV": 1, "ROI_PCT": 100,
        "RES_MODE": 0}
AI = {"enabled": True, "active": True, "source": "ai", "fps": 29.8,
      "persons": 1, "det_conf": 0.35, "kpt_conf": 0.3, "tune": {},
      "show_skeleton": True, "show_score": True, "show_label": True,
      "show_hud": False, "skeleton_only": False, "zone": [],
      "presets": [{"id": "640"}, {"id": "320"}], "detections": [],
      "events": [], "det_ms": 17.2, "pose_ms": 6.1}
FPS = 59.6
EVENTS = []
T0 = time.time()
MODE = {"id": "1080p60"}


def make_jpeg(w=640, q=60):
    try:
        from PIL import Image, ImageDraw
        im = Image.new("RGB", (w, int(w * 9 / 16)), (18, 26, 38))
        d = ImageDraw.Draw(im)
        for i in range(0, im.width, 24):
            d.line([(i, 0), (i - im.height, im.height)], fill=(30, 90, 130), width=2)
        d.rectangle([w * 0.32, im.height * 0.28, w * 0.68, im.height * 0.86],
                    outline=(239, 68, 68), width=3)
        d.text((10, 8), "FAKE BOARD  %s" % time.strftime("%H:%M:%S"), fill=(180, 210, 235))
        b = io.BytesIO()
        im.save(b, "JPEG", quality=q)
        return b.getvalue()
    except Exception:                                          # noqa: BLE001
        pass
    try:
        import cv2
        import numpy as np
        img = np.zeros((int(w * 9 / 16), w, 3), np.uint8)
        img[:] = (38, 26, 18)
        ok, enc = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), q])
        return enc.tobytes() if ok else b""
    except Exception:                                          # noqa: BLE001
        # 两个图像库都没有：返回空，让上层直接报错，别伪造一张坏 JPEG
        return b""


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        pass

    def _j(self, obj, code=200):
        b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
        except Exception:                                      # noqa: BLE001
            return {}

    def do_GET(self):
        global FPS
        u = urlparse(self.path)
        p, q = u.path, parse_qs(u.query)
        if p == "/api/status":
            with LOCK:
                return self._j({"fps": FPS, "frame_id": int((time.time() - T0) * FPS),
                                "clients": 1, "params": dict(PARAMS),
                                "device": "/dev/video22", "port": 9012})
        if p == "/api/sys":
            return self._j({"cpu": 47.3, "gpu": {"load_pct": 12.0},
                            "npu": {"load_pct": 33.0}, "ram": {"pct": 42.0},
                            "latency_ms": {"capture_to_ready": 28.2,
                                           "newest_frame_age": 12.0}})
        if p == "/api/fpga":
            with LOCK:
                out = {"ok": True, "regs": dict(REGS),
                       "status": {"CAM_ID": 0xA5, "VER": 0x4706,
                                  "FRAME_CNT": int((time.time() - T0) * FPS)},
                       "phys": {"cam_exp_ms": 16.6, "cam_exp_max_ms": 16.7,
                                "cam_gain_db": 9.6, "ev": 0, "wb_r_pct": 100,
                                "wb_b_pct": 100, "roi_pct": REGS["ROI_PCT"],
                                "res_mode": REGS["RES_MODE"], "fps": 60,
                                "res_name": MODE["id"]}}
            if "compact=1" not in (u.query or ""):
                out["meta"] = {"writable": [], "readonly": [], "presets": {}}
            return self._j(out)
        if p == "/api/ai":
            with LOCK:
                return self._j(dict(AI, ok=True, events=list(EVENTS[-10:])))
        if p == "/api/modes":
            return self._j({"ok": True, "current": MODE})
        if p in ("/snapshot.jpg", "/snapshot"):
            w = int((q.get("w") or [640])[0] or 640)
            qq = int((q.get("q") or [60])[0] or 60)
            b = make_jpeg(w, qq)
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        if p == "/mock/event":
            lab = (q.get("label") or ["fall"])[0]
            cn = {"fall": "跌倒", "fight": "肢体冲突", "climb": "攀爬翻越",
                  "intrude": "越界闯入"}.get(lab, lab)
            with LOCK:
                EVENTS.append({"t": time.time(), "tid": 2, "label": lab,
                               "cn": cn, "en": lab, "score": 0.93})
                AI["detections"] = [{"tid": 2, "box": [100, 50, 300, 400],
                                     "score": 0.95, "risk": 2, "n_kpt": 17,
                                     "labels": [cn], "labels_en": [lab]}]
            return self._j({"ok": True, "events": len(EVENTS)})
        if p == "/mock/fps":
            FPS = float((q.get("x") or ["59.6"])[0])
            return self._j({"ok": True, "fps": FPS})
        if p == "/mock/clear":
            with LOCK:
                AI["detections"] = []
            return self._j({"ok": True})
        return self._j({"error": "not found"}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        p = u.path
        b = self._body()
        print("[fake] POST %s %s" % (p, json.dumps(b, ensure_ascii=False)[:200]))
        if p == "/api/params":
            with LOCK:
                if b.get("reset"):
                    PARAMS.update({"brightness": 0, "contrast": 1.0})
                else:
                    PARAMS.update(b)
                return self._j(dict(PARAMS))
        if p == "/api/fpga":
            with LOCK:
                if "preset" in b:
                    REGS["PP_EN"] = 1
                for k, v in b.items():
                    if k in REGS:
                        REGS[k] = v
                return self._j({"ok": True, "message": "已写入 %d 个寄存器" % len(b),
                                "regs": dict(REGS)})
        if p == "/api/ai":
            with LOCK:
                AI.update({k: v for k, v in b.items() if k != "tune"})
                if "tune" in b:
                    AI["tune"].update(b["tune"])
                return self._j({"ok": True, "ai": dict(AI)})
        if p == "/api/mode":
            MODE["id"] = b.get("id") or MODE["id"]
            return self._j({"ok": True, "message": "模式已切到 %s" % MODE["id"]})
        if p == "/api/jpeg":
            return self._j({"ok": True, "hw": bool(b.get("hw"))})
        return self._j({"error": "not found"}, 404)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9100)
    a = ap.parse_args()
    s = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    s.daemon_threads = True
    print("fake board on http://127.0.0.1:%d  (GET /mock/event?label=fall)" % a.port)
    s.serve_forever()


if __name__ == "__main__":
    main()
