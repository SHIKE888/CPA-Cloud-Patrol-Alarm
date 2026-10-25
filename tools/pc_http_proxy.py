#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""最简 HTTP/HTTPS 代理（支持 CONNECT），给车端在无外网时当跳板用。

用法（PC 上，无需管理员权限）：
    python pc_http_proxy.py --port 8811

配合 SSH 反向隧道把 PC 的 127.0.0.1:8811 映射到车端 127.0.0.1:8811：
    ssh -R 8811:127.0.0.1:8811 ros "sleep infinity"

然后车端：
    sudo apt -o Acquire::http::Proxy=http://127.0.0.1:8811 update
    sudo apt -o Acquire::http::Proxy=http://127.0.0.1:8811 install -y ros-noetic-foxglove-bridge
"""
import argparse
import select
import socket
import socketserver
import sys
import threading

BUFSIZE = 65536
HOP = ('connection', 'proxy-connection', 'keep-alive', 'proxy-authorization')


def _copy(src, dst):
    try:
        while True:
            data = src.recv(BUFSIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass


def pump(a, b):
    """双向拷贝：两个线程各管一个方向，避免 select 在隧道场景下的半关闭问题"""
    t = threading.Thread(target=_copy, args=(b, a), daemon=True)
    t.start()
    _copy(a, b)
    t.join(timeout=5)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(30)
            head = b''
            while b'\r\n\r\n' not in head and len(head) < 65536:
                chunk = self.request.recv(BUFSIZE)
                if not chunk:
                    return
                head += chunk
            line = head.split(b'\r\n', 1)[0].decode('latin-1')
            parts = line.split()
            if len(parts) < 3:
                return
            method, target = parts[0], parts[1]

            if method.upper() == 'CONNECT':
                host, _, port = target.rpartition(':')
                upstream = socket.create_connection((host, int(port or 443)), 15)
                self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
                rest = head.split(b'\r\n\r\n', 1)[1]
                if rest:
                    upstream.sendall(rest)
                self.request.settimeout(None)
                upstream.settimeout(None)
                pump(self.request, upstream)
                return

            # 普通 HTTP：target 是绝对 URL
            if not target.lower().startswith('http://'):
                self.request.sendall(b'HTTP/1.1 400 Bad Request\r\n\r\n')
                return
            hostport, _, path = target[7:].partition('/')
            host, _, port = hostport.partition(':')
            upstream = socket.create_connection((host, int(port or 80)), 15)
            headers = [l for l in head.split(b'\r\n')[1:] if l]
            keep = [l for l in headers
                    if l.split(b':', 1)[0].strip().lower().decode('latin-1') not in HOP]
            req = b'%s /%s HTTP/1.0\r\n' % (method.encode(), path.encode())
            req += b'\r\n'.join(keep) + b'\r\n\r\n'
            req += head.split(b'\r\n\r\n', 1)[1]
            upstream.sendall(req)
            self.request.settimeout(None)
            upstream.settimeout(None)
            pump(self.request, upstream)
        except Exception as e:
            try:
                self.request.sendall(b'HTTP/1.1 502 Bad Gateway\r\n\r\n')
            except Exception:
                pass
            sys.stderr.write('proxy err: %r\n' % (e,))


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=8811)
    a = ap.parse_args()
    srv = Server((a.host, a.port), Handler)
    print('proxy listening on %s:%d' % (a.host, a.port), flush=True)
    srv.serve_forever()
