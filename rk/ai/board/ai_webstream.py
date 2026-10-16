#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ai_webstream.py —— RK3576 NPU 人体检测 / 姿态关键点 / 危险动作识别 + 标注叠加 + Web 查看

架构（帧率解耦，视频帧率不受 AI 影响）
    ┌─ Capture 线程 : 只读最新帧（决定视频帧率，如 25~30fps）
    ├─ Infer   线程 : 限频（--ai-fps，如 6fps）取最新帧 → yolov8n 人体 → yolov8n-pose 关节
    │                 → 跟踪平滑（EMA）→ 危险动作状态机
    ├─ Render  线程 : 按采集帧率取最新帧 + 最近一次 AI 结果 → 叠加标注 → JPEG
    └─ HTTP    线程 : MJPEG 推流 / 单帧快照 / JSON 状态 / 在线调参

用法（板上）：
    python3 ai_webstream.py --det-model models/yolov8n.rknn \
                            --pose-model models/yolov8n-pose.rknn \
                            --device /dev/video22 --port 9013 --ai-fps 6
然后在浏览器打开 http://<板子IP>:9013/
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from action_rules import ActionRecognizer, LEVEL_ALARM, LEVEL_WARN  # noqa: E402
from det_core import SimpleTracker, TwoStageDetector, draw_person  # noqa: E402

VIEWER_HTML = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>RK3576 人体检测 / 危险动作识别</title>
<style>
 body{margin:0;background:#111;color:#ddd;font:14px/1.5 system-ui,"Microsoft YaHei",sans-serif}
 header{padding:10px 14px;background:#1b1b1b;display:flex;gap:14px;align-items:center;flex-wrap:wrap}
 h1{font-size:16px;margin:0;font-weight:600}
 .kv{color:#8bffb0;font-variant-numeric:tabular-nums}
 button{background:#2a2a2a;color:#ddd;border:1px solid #444;border-radius:6px;padding:5px 10px;cursor:pointer}
 button:hover{background:#333}
 .wrap{display:flex;gap:12px;padding:12px;flex-wrap:wrap}
 img{max-width:min(1280px,96vw);border:1px solid #333;border-radius:8px;background:#000}
 .panel{min-width:260px;background:#181818;border:1px solid #2c2c2c;border-radius:8px;padding:10px}
 .row{display:flex;justify-content:space-between;padding:3px 0;border-bottom:1px dashed #262626}
 .ev{color:#ff9b9b}
 .pill{display:inline-block;padding:1px 7px;border-radius:9px;background:#333;margin-left:6px;font-size:12px}
 input[type=range]{width:130px;vertical-align:middle}
</style></head><body>
<header>
  <h1>RK3576：人体 → 姿态 → 危险动作（NPU）</h1>
  <span class="kv" id="fps">-</span>
  <button id="toggle">暂停 AI</button>
</header>
<div class="wrap">
  <div><img id="v" src="/stream" alt="stream"></div>
  <div class="panel">
    <div class="row"><span>视频帧率</span><b id="vfps">-</b></div>
    <div class="row"><span>YOLO 帧率</span><b id="afps">-</b></div>
    <div class="row"><span>一级检测帧率</span><b id="dfps">-</b></div>
    <div class="row"><span>推理耗时 检测/姿态</span><b id="ms">-</b></div>
    <div class="row"><span>人数</span><b id="np">-</b></div>
    <div class="row"><span>模型</span><b id="mdl">-</b></div>
    <div class="row"><span>动作阈值</span><b id="th">-</b></div>
    <div style="margin-top:8px">
      <div class="row"><span>跌倒灵敏度</span><input type="range" id="r_fall" min="0.3" max="1" step="0.05"></div>
      <div class="row"><span>奔跑灵敏度</span><input type="range" id="r_run" min="0.5" max="2.5" step="0.05"></div>
      <div class="row"><span>AI 帧率</span><input type="range" id="r_fps" min="1" max="15" step="1"></div>
    </div>
    <div style="margin-top:10px;font-weight:600">检测结果 <span id="dt" style="font-weight:400;color:#888"></span></div>
    <div id="dets" style="max-height:150px;overflow:auto;font-size:13px"></div>
    <div style="margin-top:10px;font-weight:600">事件</div>
    <div id="evs" style="max-height:220px;overflow:auto;font-size:13px"></div>
  </div>
</div>
<script>
const $=id=>document.getElementById(id);
const fmt=(v,n=1)=>v==null?'-':Number(v).toFixed(n);
async function poll(){
  try{
    const s=await (await fetch('/api/status',{cache:'no-store'})).json();
    $('fps').textContent='视频 '+fmt(s.video_fps)+'fps  |  YOLO '+fmt(s.ai_fps)+'fps';
    $('vfps').textContent=fmt(s.video_fps)+' fps';
    $('afps').textContent=fmt(s.ai_fps)+' / '+fmt(s.ai_fps_target,0)+' fps';
    $('dfps').textContent=fmt(s.fps_det)+' fps';
    $('ms').textContent=fmt(s.det_ms)+' / '+fmt(s.pose_ms)+' ms';
    $('np').textContent=s.persons;
    $('dt').textContent=s.age_ms==null?'':'（'+s.age_ms.toFixed(0)+' ms 前）';
    const de=s.detections||[];
    $('dets').innerHTML=de.length? de.map(d=>'<div style="color:'+
        (d.risk>=2?'#ff7b7b':(d.risk>=1?'#ffc266':'#8bffb0'))+'">ID'+(d.tid==null?'-':d.tid)+
        ' '+(d.score*100).toFixed(0)+'% 框('+d.box.join(',')+') 关节'+d.n_kpt+'/17'+
        ((d.labels_en||[]).length?' · '+(d.labels_en||[]).map((w,i)=>w+
          ((d.labels||[])[i]?' '+(d.labels||[])[i]:'')).join('/'):'')+'</div>').join('')
      :'<div style="color:#666">未检出人体</div>';
    $('mdl').textContent=(s.det_ok?'det✓':'det✗')+' '+(s.pose_ok?'pose✓':'pose✗');
    $('th').textContent='conf '+s.det_conf.toFixed(2)+' / nms '+s.nms_thres.toFixed(2);
    $('evs').innerHTML=(s.events||[]).slice().reverse().map(e=>'<div class="ev">'+
        new Date(e.t*1000).toLocaleTimeString()+' ID'+e.tid+' '+(e.en||e.label||e.cn)+' '+
        (e.score*100).toFixed(0)+'%</div>').join('')||'<div style="color:#666">暂无</div>';
    if(document.activeElement!==$('r_fall')) $('r_fall').value=s.tune.fall;
    if(document.activeElement!==$('r_run')) $('r_run').value=s.tune.run;
    if(document.activeElement!==$('r_fps')) $('r_fps').value=s.ai_fps_target;
    $('toggle').textContent=s.enabled?'暂停 AI':'开启 AI';
  }catch(e){ $('fps').textContent='连接中断'; }
}
async function push(patch){ await fetch('/api/ai',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(patch)}); }
$('r_fall').oninput=e=>push({tune:{fall:+e.target.value}});
$('r_run').oninput=e=>push({tune:{run:+e.target.value}});
$('r_fps').oninput=e=>push({ai_fps:+e.target.value});
$('toggle').onclick=()=>{ $('v').src='/stream?'+Date.now(); };
setInterval(poll,700); poll();
</script></body></html>
"""


def _act_en(a):
    """动作英文名（给 cv2 用）：en -> label -> cn。"""
    return a.get('en') or a.get('label') or a.get('cn') or '?'


def _ascii(s):
    """只保留 ASCII —— cv2.putText 画不了中文，直接传会变成一串 '???'。"""
    return ''.join(c for c in str(s) if ord(c) < 128) or '?'


# ------------------------------------------------------------------ 帧交换中枢

class Shared(object):
    """采集 / 推理 / 渲染 三个线程之间的最新值交换（永远只保留最新）。"""

    def __init__(self):
        self.lock = threading.Lock()
        self.frame = None
        self.seq = 0
        self.frame_t = 0.0
        self.result = None          # 最近一次 AI 结果
        self.result_seq = -1
        self.result_t = 0.0
        self.stats = {'video_fps': 0.0, 'ai_fps': 0.0, 'capture_fps': 0.0}

    def put_frame(self, frame):
        with self.lock:
            self.frame = frame
            self.seq += 1
            self.frame_t = time.time()
            return self.seq

    def get_frame(self):
        with self.lock:
            return self.frame, self.seq, self.frame_t

    def put_result(self, result, seq):
        with self.lock:
            self.result = result
            self.result_seq = seq
            self.result_t = time.time()

    def get_result(self):
        with self.lock:
            return self.result, self.result_seq, self.result_t


class FrameHub(object):
    """MJPEG 广播：所有 HTTP 客户端共享同一个 JPEG 序号。"""

    def __init__(self):
        self.cv = threading.Condition()
        self.id = 0
        self.jpeg = None
        self.info = {}

    def publish(self, jpeg, info=None):
        with self.cv:
            self.id += 1
            self.jpeg = jpeg
            if info:
                self.info = info
            self.cv.notify_all()

    def wait(self, last_id, timeout=5.0):
        with self.cv:
            if self.id == last_id:
                self.cv.wait(timeout)
            return self.id, self.jpeg

    def snapshot(self):
        with self.cv:
            return self.id, self.jpeg, dict(self.info)


# ------------------------------------------------------------------ 三个工作线程

class CaptureThread(threading.Thread):
    def __init__(self, args, shared):
        super().__init__(daemon=True)
        self.args = args
        self.shared = shared
        self.stop_flag = False
        self.cap = None
        self.n = 0
        self.t0 = time.time()
        self.real_w = self.real_h = 0
        self.is_url = False
        self.is_image = False
        self.img = None

    def _open(self):
        src = self.args.source or self.args.device
        if src.startswith('file:'):
            src = src[5:]
        if os.path.isfile(src):
            self.img = cv2.imread(src)
            if self.img is None:
                time.sleep(1.0)
                return False
            self.is_image = True
            self.real_h, self.real_w = self.img.shape[:2]
            print('[capture] 图片循环源 %s  %dx%d  %.1f fps'
                  % (src, self.real_w, self.real_h, self.args.source_fps))
            return True
        self.is_url = src.split('://')[0] in ('http', 'https', 'rtsp', 'rtmp')
        if self.is_url:
            # 接入已有视频流（MJPEG over HTTP / RTSP），不占用摄像头设备
            self.cap = cv2.VideoCapture(src)
            self.real_w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
            self.real_h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
            print('[capture] 接入流 %s  %dx%d  opened=%s'
                  % (src, self.real_w, self.real_h, self.cap.isOpened()))
            if not self.cap.isOpened():
                time.sleep(1.0)
                return False
            return True

        self.cap = cv2.VideoCapture(self.args.device, cv2.CAP_V4L2)
        if not self.cap.isOpened():
            self.cap = cv2.VideoCapture(self.args.device)
        if not self.cap.isOpened():
            time.sleep(1.0)
            return False
        self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*self.args.fourcc))
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.args.width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.args.height)
        if self.args.buffersize:
            self.cap.set(cv2.CAP_PROP_BUFFERSIZE, self.args.buffersize)
        self.real_w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.real_h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        print('[capture] %s  %dx%d  fourcc=%s'
              % (self.args.device, self.real_w, self.real_h, self.args.fourcc))
        return True

    def run(self):
        while not self.stop_flag:
            if self.cap is None and not self.is_image:
                if not self._open():
                    continue
            if self.is_image:
                self.shared.put_frame(self.img)
                self.n += 1
                now = time.time()
                if now - self.t0 >= 1.0:
                    self.shared.stats['capture_fps'] = self.n / (now - self.t0)
                    self.n = 0
                    self.t0 = now
                time.sleep(1.0 / max(1.0, self.args.source_fps))
                continue
            _t_read = time.time()
            ok, frame = self.cap.read()
            if not ok or frame is None:
                print('[capture] read 失败，重开设备')
                try:
                    self.cap.release()
                except Exception:  # noqa: BLE001
                    pass
                self.cap = None
                time.sleep(0.5)
                continue
            self.shared.put_frame(frame)
            self.n += 1
            now = time.time()
            if now - self.t0 >= 1.0:
                self.shared.stats['capture_fps'] = self.n / (now - self.t0)
                self.n = 0
                self.t0 = now
            # 可选限频：网络流往往会以高于源帧率的速度交回重复帧，白烧 CPU
            if self.args.cap_fps > 0:
                rest = 1.0 / self.args.cap_fps - (time.time() - _t_read)
                if rest > 0:
                    time.sleep(rest)

    def release(self):
        self.stop_flag = True
        if self.cap is not None:
            self.cap.release()


class InferThread(threading.Thread):
    def __init__(self, args, shared, detector, tracker, actions, state):
        super().__init__(daemon=True)
        self.args = args
        self.shared = shared
        self.det = detector
        self.tracker = tracker
        self.actions = actions
        self.state = state
        self.stop_flag = False
        self.n = 0
        self.t0 = time.time()

    def run(self):
        last_seq = -1
        while not self.stop_flag:
            if not self.state['enabled']:
                time.sleep(0.05)
                continue
            t_start = time.time()
            frame, seq, _ = self.shared.get_frame()
            if frame is None or seq == last_seq:
                time.sleep(0.004)
                continue
            last_seq = seq

            try:
                img = frame.copy() if args.copy_frame else frame
                dets = self.det.run(img)                    # Stage1 + Stage2
                dets = self.tracker.update(t_start, dets)     # 跟踪 + 平滑
                dets = self.actions.update(t_start, dets)     # 危险动作
            except Exception as e:  # noqa: BLE001
                print('[infer] 异常: %s' % e)
                time.sleep(0.2)
                continue

            self.shared.put_result(dets, seq)
            self.n += 1
            now = time.time()
            if now - self.t0 >= 1.0:
                self.shared.stats['ai_fps'] = self.n / (now - self.t0)
                self.n = 0
                self.t0 = now

            # 独立限频：AI 帧率与视频帧率互不影响
            target = 1.0 / max(0.2, float(self.state['ai_fps']))
            rest = target - (time.time() - t_start)
            if rest > 0:
                time.sleep(rest)


class RenderThread(threading.Thread):
    def __init__(self, args, shared, hub, state, detector):
        super().__init__(daemon=True)
        self.args = args
        self.shared = shared
        self.hub = hub
        self.state = state
        self.detector = detector
        self.stop_flag = False
        self.n = 0
        self.t0 = time.time()
        self.enc_params = [int(cv2.IMWRITE_JPEG_QUALITY), args.quality]
        self.stale_ms = args.stale_ms

    def _overlay(self, frame, dets, age_ms):
        args = self.args
        h, w = frame.shape[:2]

        # 警戒区
        zone = self.state.get('zone') or []
        if zone:
            pts = np.array([[int(x * w), int(y * h)] for x, y in zone], dtype=np.int32)
            overlay = frame.copy()
            cv2.fillPoly(overlay, [pts], (0, 0, 90))
            cv2.addWeighted(overlay, 0.25, frame, 0.75, 0, frame)
            cv2.polylines(frame, [pts], True, (0, 80, 255), 2, cv2.LINE_AA)
            cv2.putText(frame, 'ALERT ZONE', (pts[:, 0].min(), max(18, pts[:, 1].min() - 6)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 80, 255), 2, cv2.LINE_AA)

        n_risk = 0
        if dets:
            for d in dets:
                acts = d.get('actions') or []
                level = d.get('risk', 0)
                if level >= LEVEL_ALARM:
                    color, thick = (0, 0, 255), 3
                    n_risk += 1
                elif level >= LEVEL_WARN:
                    color, thick = (0, 165, 255), 3
                else:
                    color, thick = (0, 255, 0), 2

                label = ''
                if acts:
                    a0 = acts[0]
                    # 画面上只能用英文: cv2.putText 画不了中文(会变成 "???")
                    label = '%s %.0f%%' % (_act_en(a0), a0['score'] * 100)
                    if len(acts) > 1:
                        label += ' /' + _act_en(acts[1])
                tid = d.get('tid')
                label = _ascii(('ID%d %s' % (tid, label)).strip())

                if args.no_skeleton:
                    draw_person(frame, d['box'], d['score'], label, color, thick,
                                kps=None, show_score=not args.no_score)
                else:
                    draw_person(frame, d['box'], d['score'], label, color, thick,
                                kps=d.get('kps'), show_score=not args.no_score)

                # 动作标签：多人时把标签再放一行，便于观察（英文，cv2 画不了中文）
                if acts and args.verbose_label:
                    y = int(d['box'][3]) + 20
                    for i, a in enumerate(acts[:2]):
                        cv2.putText(frame, _ascii('%s %.0f%%' % (_act_en(a), a['score'] * 100)),
                                    (int(d['box'][0]), min(h - 6, y + i * 20)),
                                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, a['color'], 2, cv2.LINE_AA)

        # 顶部信息条
        st = self.shared.stats
        det_ms = self.detector.det.infer_ms if self.detector.det else 0.0
        pose_ms = self.detector.pose.infer_ms if self.detector.pose else 0.0
        info = 'video %.1ffps | AI %.1ffps | det %.1fms pose %.1fms | persons %d%s' % (
            st.get('capture_fps', 0.0), st.get('ai_fps', 0.0),
            det_ms, pose_ms, len(dets or []),
            '  (AI 结果 %.0fms 前)' % age_ms if age_ms > self.stale_ms else '')
        cv2.rectangle(frame, (0, 0), (w, 26), (25, 25, 25), -1)
        cv2.putText(frame, info, (8, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                    (0, 255, 160), 1, cv2.LINE_AA)
        if n_risk:
            cv2.putText(frame, '! %d' % n_risk, (w - 60, 20),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2, cv2.LINE_AA)
        return frame

    def run(self):
        last_seq = -1
        while not self.stop_flag:
            frame, seq, _ = self.shared.get_frame()
            if frame is None or seq == last_seq:
                time.sleep(0.003)
                continue
            last_seq = seq

            t = time.time()
            result, rseq, rt = self.shared.get_result()
            age_ms = (t - rt) * 1000.0 if rt else 1e9
            enabled = self.state['enabled']
            dets = result if (enabled and age_ms < self.args.stale_ms) else []

            vis = self._overlay(frame.copy(), dets, age_ms)

            sw = self.args.stream_width
            if sw and sw > 0 and vis.shape[1] > sw:
                r = sw / float(vis.shape[1])
                vis = cv2.resize(vis, (sw, max(2, int(vis.shape[0] * r))),
                                 interpolation=cv2.INTER_AREA)
            ok, buf = cv2.imencode('.jpg', vis, self.enc_params)
            if ok:
                self.hub.publish(buf.tobytes(), {'persons': len(dets)})

            self.n += 1
            now = time.time()
            if now - self.t0 >= 1.0:
                self.shared.stats['video_fps'] = self.n / (now - self.t0)
                self.n = 0
                self.t0 = now


# ------------------------------------------------------------------ HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = 'rk3576-ai/1.0'
    protocol_version = 'HTTP/1.1'
    hub = None
    app = None

    def log_message(self, fmt, *a):  # noqa: A003
        if self.app and self.app['args'].verbose:
            sys.stderr.write('[http] %s\n' % (fmt % a))

    def _send(self, code, ctype, body, extra=None):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header('Connection', 'close')
        self.close_connection = True
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, 'application/json; charset=utf-8',
                   json.dumps(obj, ensure_ascii=False).encode('utf-8'))

    def do_OPTIONS(self):  # noqa: N802
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):  # noqa: N802
        path = self.path.split('?')[0]
        if path in ('/', '/index.html'):
            self._send(200, 'text/html; charset=utf-8', VIEWER_HTML.encode('utf-8'))
        elif path == '/stream':
            self._stream()
        elif path == '/snapshot.jpg':
            _, jpeg, _ = self.hub.snapshot()
            if jpeg is None:
                self._send(503, 'text/plain', b'no frame')
            else:
                self._send(200, 'image/jpeg', jpeg)
        elif path == '/api/status':
            self._json(self.app['status']())
        elif path == '/api/ai':
            self._json(self.app['state_view']())
        else:
            self._send(404, 'text/plain; charset=utf-8', '404'.encode('utf-8'))

    def do_POST(self):  # noqa: N802
        path = self.path.split('?')[0]
        if path not in ('/api/ai', '/api/params'):
            self._send(404, 'text/plain', b'404')
            return
        try:
            n = int(self.headers.get('Content-Length') or 0)
            patch = json.loads(self.rfile.read(n) or b'{}')
        except Exception as e:  # noqa: BLE001
            self._json({'ok': False, 'err': str(e)}, 400)
            return
        self._json(self.app['apply'](patch))

    def _stream(self):
        self.send_response(200)
        self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        last = -1
        try:
            while True:
                last, jpeg = self.hub.wait(last, timeout=5.0)
                if jpeg is None:
                    continue
                self.wfile.write(b'--frame\r\nContent-Type: image/jpeg\r\n'
                                 b'Content-Length: %d\r\n\r\n' % len(jpeg))
                self.wfile.write(jpeg)
                self.wfile.write(b'\r\n')
        except Exception:  # noqa: BLE001
            return


# ------------------------------------------------------------------ main

def build_app(args, shared, hub, detector, actions, state):
    def status():
        st = shared.stats
        res, rseq, rt = shared.get_result()
        dets = res or []
        # 一级检测真实执行帧率：用累计计数在两秒窗口里差分
        now = time.time()
        dn = detector.stat.get('det_n', 0)
        probe = state.get('_fps_probe')
        if probe is None:
            state['_fps_probe'] = {'t': now, 'det_n': dn}
        elif now - probe['t'] >= 2.0:
            st['det_fps'] = (dn - probe['det_n']) / (now - probe['t'])
            probe['t'], probe['det_n'] = now, dn
        rows = []
        for d in dets:
            kps = d.get('kps')
            try:
                n_kpt = int((kps[:, 2] > 0).sum()) if kps is not None else 0
            except Exception:                                   # noqa: BLE001
                n_kpt = 0
            rows.append({'tid': d.get('tid'),
                         'box': [int(v) for v in d.get('box', [0, 0, 0, 0])],
                         'score': round(float(d.get('score', 0)), 3),
                         'risk': d.get('risk', 0), 'n_kpt': n_kpt,
                         'labels': [a['cn'] for a in (d.get('actions') or [])],
                         'labels_en': [a.get('en') or a.get('label') or a.get('cn')
                                       for a in (d.get('actions') or [])]})
        return {
            'video_fps': round(st.get('capture_fps', 0.0), 2),
            'render_fps': round(st.get('video_fps', 0.0), 2),
            'ai_fps': round(st.get('ai_fps', 0.0), 2),
            'fps_det': round(st.get('det_fps', 0.0), 2),
            'ai_fps_target': state['ai_fps'],
            'det_ms': round(detector.det.infer_ms, 2) if detector.det else 0,
            'pose_ms': round(detector.pose.infer_ms, 2) if detector.pose else 0,
            'persons': len(dets),
            'det_ok': bool(detector.det and detector.det.ok),
            'pose_ok': bool(detector.pose and detector.pose.ok),
            'det_err': detector.det.err if detector.det else 'no model',
            'pose_err': detector.pose.err if detector.pose else 'no model',
            'det_conf': detector.det_conf,
            'nms_thres': detector.nms_thres,
            'kpt_margin': detector.kpt_margin,
            'roi_expand': detector.roi_expand,
            'enabled': state['enabled'],
            'age_ms': round((time.time() - rt) * 1000.0, 1) if rt else None,
            'tune': actions.tune,
            'zone': state.get('zone') or [],
            'events': list(actions.events)[-20:],
            'detections': rows,
            'actions': [{'tid': d.get('tid'), 'risk': d.get('risk', 0),
                         'labels': [a['cn'] for a in (d.get('actions') or [])]} for d in dets],
        }

    def state_view():
        return {'enabled': state['enabled'], 'ai_fps': state['ai_fps'],
                'tune': actions.tune, 'zone': state.get('zone') or [],
                'det_conf': detector.det_conf, 'nms_thres': detector.nms_thres}

    def apply(patch):
        if 'enabled' in patch:
            state['enabled'] = bool(patch['enabled'])
        if 'ai_fps' in patch:
            state['ai_fps'] = max(0.2, min(30.0, float(patch['ai_fps'])))
        if 'det_conf' in patch:
            detector.det_conf = max(0.05, min(0.95, float(patch['det_conf'])))
        if 'nms_thres' in patch:
            detector.nms_thres = max(0.05, min(0.95, float(patch['nms_thres'])))
        if 'kpt_margin' in patch:
            v = max(-1.0, min(2.0, float(patch['kpt_margin'])))
            detector.kpt_margin = v
            actions.box_margin = v
        if 'zone' in patch:
            state['zone'] = patch['zone'] or []
            actions.alert_polygon = state['zone']
        if 'tune' in patch and isinstance(patch['tune'], dict):
            for k, v in patch['tune'].items():
                actions.tune[k] = float(v)
        return {'ok': True, 'state': state_view()}

    return {'status': status, 'state_view': state_view, 'apply': apply, 'args': args}


def guess_ip():
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except Exception:  # noqa: BLE001
        return '127.0.0.1'
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser(description='RK3576 人体检测/姿态/危险动作 标注推流')
    ap.add_argument('--device', default='/dev/video22', help='V4L2 设备')
    ap.add_argument('--source', default='',
                    help='视频源（优先于 --device）：http(s)://ip:port/stream、rtsp://… 或图片路径'
                         '（图片会被循环帧发送，用于演示）'
                         '例如接入现有推流：http://127.0.0.1:9012/stream')
    ap.add_argument('--source-fps', type=float, default=25.0, help='图片循环源的发送帧率')
    ap.add_argument('--cap-fps', type=float, default=0.0,
                    help='采集限频（0=不限）；接网络流时建议 20~25，避免拉重复帧白烧 CPU')
    ap.add_argument('--width', type=int, default=1920)
    ap.add_argument('--height', type=int, default=1080)
    ap.add_argument('--fourcc', default='NV12', help='采集像素格式（NV12/NV16/YUYV）')
    ap.add_argument('--buffersize', type=int, default=2)
    ap.add_argument('--det-model', default='models/yolov8n.rknn')
    ap.add_argument('--pose-model', default='models/yolov8n-pose-hybrid.rknn',
                    help='推荐用混合量化版（关键点 conf 才不会被 INT8 压没）')
    ap.add_argument('--det-conf', type=float, default=0.35)
    ap.add_argument('--nms-thres', type=float, default=0.45)
    ap.add_argument('--kpt-conf', type=float, default=0.30)
    ap.add_argument('--max-persons', type=int, default=4, help='每帧最多跑几个姿态（ROI）')
    ap.add_argument('--roi-expand', type=float, default=1.15)
    ap.add_argument('--kpt-margin', type=float, default=0.15,
                    help='一级框约束: 关节只保留在人体框 ± 该比例范围内 '
                         '(默认 0.15, <0 = 不限制)。二级关键点与三级动作判定同时生效')
    ap.add_argument('--det-interval', type=int, default=2,
                    help='一级检测跳帧(默认 2)；1=每帧都检测(最准最慢)')
    ap.add_argument('--copy-frame', action='store_true',
                    help='推理前拷一份整帧(默认不拷，省约 2.5ms/帧)')
    ap.add_argument('--ai-fps', type=float, default=6.0, help='AI 推理帧率上限（与视频帧率独立）')
    ap.add_argument('--port', type=int, default=9013)
    ap.add_argument('--host', default='0.0.0.0')
    ap.add_argument('--stream-width', type=int, default=1280)
    ap.add_argument('--quality', type=int, default=72)
    ap.add_argument('--stale-ms', type=float, default=1500.0, help='AI 结果过期阈值(ms)，超过则不叠加')
    ap.add_argument('--threads', type=int, default=4, help='OpenCV 线程数')
    ap.add_argument('--zone', default='', help='警戒区，归一化坐标 例 "0.2,0.6;0.8,0.6;0.8,1;0.2,1"')
    ap.add_argument('--no-skeleton', action='store_true', help='不画骨架')
    ap.add_argument('--no-score', action='store_true', help='不显示置信度')
    ap.add_argument('--verbose-label', action='store_true', help='框下方再打印动作中文标签')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    cv2.setNumThreads(args.threads)

    zone = []
    if args.zone:
        try:
            for pt in args.zone.split(';'):
                x, y = pt.split(',')
                zone.append((float(x), float(y)))
        except Exception:  # noqa: BLE001
            print('[warn] --zone 解析失败，忽略')

    detector = TwoStageDetector(args.det_model, args.pose_model,
                                det_conf=args.det_conf, nms_thres=args.nms_thres,
                                kpt_conf=args.kpt_conf, max_persons=args.max_persons,
                                roi_expand=args.roi_expand,
                                kpt_margin=args.kpt_margin,
                                det_interval=args.det_interval)
    print('[model] det  : %s -> %s' % (args.det_model,
                                       'OK' if detector.det and detector.det.ok else
                                       'FAIL(%s)' % (detector.det.err if detector.det else 'n/a')))
    print('[model] pose : %s -> %s' % (args.pose_model,
                                       'OK' if detector.pose and detector.pose.ok else
                                       'FAIL(%s)' % (detector.pose.err if detector.pose else 'n/a')))

    actions = ActionRecognizer(alert_polygon=zone, box_margin=args.kpt_margin)
    tracker = SimpleTracker()
    shared = Shared()
    hub = FrameHub()
    state = {'enabled': True, 'ai_fps': args.ai_fps, 'zone': zone}

    app = build_app(args, shared, hub, detector, actions, state)
    Handler.hub = hub
    Handler.app = app

    cap = CaptureThread(args, shared)
    inf = InferThread(args, shared, detector, tracker, actions, state)
    ren = RenderThread(args, shared, hub, state, detector)

    cap.start()
    inf.start()
    ren.start()

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    ip = guess_ip()
    print('=' * 62)
    print('  浏览器打开:  http://%s:%d/' % (ip, args.port))
    print('  快照:        http://%s:%d/snapshot.jpg' % (ip, args.port))
    print('  状态 JSON:   http://%s:%d/api/status' % (ip, args.port))
    print('  AI 帧率 %.1f / 视频 采集自 %s %dx%d' % (args.ai_fps, args.device, args.width, args.height))
    print('=' * 62)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print('\n[exit] 正在退出…')
    finally:
        cap.release()
        inf.stop_flag = True
        ren.stop_flag = True
        if detector.det:
            detector.det.release()
        if detector.pose:
            detector.pose.release()


if __name__ == '__main__':
    main()
