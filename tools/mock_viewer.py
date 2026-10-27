# -*- coding: utf-8 -*-
"""本地假后端：只为了在 PC 上**看**「云台」页签的排版/交互（不需要板子）。

它伪装出 mipi_webstream 会被前端调到的那几个接口，其中
``/api/gimbal`` 用的是真的 ``gimbal_web.GimbalWeb``（串口换成 test_gimbal_web
里的假固件），所以角度/限幅/追踪数字都是真的在跑。

    python tools/mock_viewer.py [--port 18080]
    然后用浏览器打开 http://127.0.0.1:18080/ ，点右上「云台」页签。
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import test_gimbal_web as T                                   # noqa: E402

G = T.gimbal_web
PAGE = os.path.join(HERE, "..", "rk", "relay", "web", "console.html")
VENDOR = os.path.join(HERE, "..", "rk", "relay", "web", "vendor")
PARAMS = {"brightness": 0, "contrast": 1.0, "saturation": 1.0, "hue": 0,
          "gamma": 1.0, "mirror": 0, "flipv": 0, "rotate": 0, "scale": 1.0,
          "quality": 80, "fps": 60, "dual": 0, "dual_demo": 0, "ai_src": 0,
          "jpeg_ll": 0, "jpeg_q": 75, "jpeg_kb": 120, "jpeg_rc": 0}

GZ = G.GimbalWeb(port="fake", yaw_limit_deg=170.0, pitch_limit_deg=42.0,
                 speed_max=25.0, state_path=None, ai_status=T.fake_ai)


def ai_now():
    d = T.fake_ai()
    d.update({"ok": True, "enabled": True, "source": "detect",
              "fps": 31.4, "fps_target": 30.0, "fps_det": 15.8, "fps_pose": 30.0,
              "det_ms": 16.9, "pose_ms": 7.8, "persons": len(d["detections"]),
              "age_ms": 28.0, "events": [], "tune": {},
              "presets": [{"id": "accurate", "name": "精准", "cur": True}],
              "preset": "accurate",
              "models": {"det": "yolov8n", "pose": "yolov8n-pose"}})
    return d


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def _send(self, body, ctype="application/json; charset=utf-8", code=200):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(b"", code=204)

    def do_GET(self):
        p = self.path.split("?", 1)[0]
        if p in ("/", "/index.html", "/viewer"):
            with io.open(PAGE, "rb") as f:
                return self._send(f.read(), "text/html; charset=utf-8")
        if p.startswith("/vendor/"):
            fp = os.path.abspath(os.path.join(VENDOR, p[len("/vendor/"):]))
            if fp.startswith(os.path.abspath(VENDOR)) and os.path.isfile(fp):
                with io.open(fp, "rb") as f:
                    return self._send(f.read(), "application/javascript")
            return self._send(b"", "text/plain", 404)
        if p == "/api/gimbal":
            return self._send(GZ.status())
        if p == "/api/ai":
            return self._send(ai_now())
        if p == "/api/params":
            return self._send(PARAMS)
        if p == "/api/status":
            return self._send({"fps": 59.6, "width": 1920, "height": 1080,
                               "backend": "test", "device": "/dev/video22",
                               "clients": 1, "frame_id": 1234,
                               "params": PARAMS, "ai": ai_now(), "dual": None})
        if p == "/api/sys":
            return self._send({"cpu": {"total": 42, "cores": [40, 44]},
                               "npu": {"load_pct": 31, "freq_mhz": 1000},
                               "mem": {"used_pct": 51, "used_mb": 980,
                                       "total_mb": 1900},
                               "rev": {}})
        if p == "/api/fpga":
            return self._send({"ok": True, "regs": {}, "status": {}, "phys": {},
                               "meta": []})
        if p == "/api/modes":
            return self._send({"ok": True, "resolutions": [], "current": None,
                               "link_mb_s": 500})
        if p == "/api/net":
            return self._send({"ok": True, "port": self.server.server_port,
                               "ips": ["127.0.0.1"],
                               "nets": [{"iface": "lo", "ip": "127.0.0.1"}]})
        if p == "/api/jpeg":
            return self._send({"ok": True, "hw": True, "active": False,
                               "stat": {}})
        if p in ("/snapshot.jpg", "/snapshot", "/stream"):
            return self._send(b"", "image/jpeg", 404)
        return self._send({"error": "not found", "path": p}, code=404)

    def do_POST(self):
        p = self.path.split("?", 1)[0]
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except Exception:                                      # noqa: BLE001
            body = {}
        if p == "/api/gimbal":
            return self._send(GZ.apply(body))
        if p == "/api/params":
            PARAMS.update(body or {})
            return self._send(PARAMS)
        if p == "/api/ai":
            return self._send({"ok": True, "ai": ai_now()})
        return self._send({"ok": True})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--page", default=None,
                 help="要预览的 HTML（默认 rk/relay/web/console.html；"
                      "mipi_viewer.html 已于 2026-10-28 移除）")
    a = ap.parse_args()
    global PAGE
    if a.page:
        PAGE = os.path.abspath(a.page)
    GZ.start()
    GZ._want_open = True
    time.sleep(0.8)
    # 摆一个好看点的初始姿态：转到 (±12°, +6°) 附近
    GZ.apply({"action": "jog", "yaw": 25.0, "pitch": 10.0, "hold": 0.6})
    time.sleep(0.55)
    GZ.apply({"action": "stop"})
    print("mock viewer: http://127.0.0.1:%d/   (云台页签)" % a.port)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    srv.daemon_threads = True
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        GZ.stop()


if __name__ == "__main__":
    main()
