#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""最简 WebSocket 握手探针：发一次 GET，打印服务端返回的状态行。

用法:
    python3 ws_probe.py 192.168.100.87 9090 /
    python3 ws_probe.py 127.0.0.1 80 /rosbridge

期望:
    直连 rosbridge  -> 101 Switching Protocols
    经 nginx 反代   -> 也应该是 101；若是 400，说明 nginx 没把 Upgrade 传下去。
"""
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
path = sys.argv[3] if len(sys.argv) > 3 else '/'

req = (
    'GET %s HTTP/1.1\r\n'
    'Host: %s:%d\r\n'
    'Upgrade: websocket\r\n'
    'Connection: Upgrade\r\n'
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    'Sec-WebSocket-Version: 13\r\n'
    '\r\n'
) % (path, host, port)

try:
    s = socket.create_connection((host, port), 5)
except Exception as e:
    print('%s:%d%s  CONNECT-FAIL  %s' % (host, port, path, e))
    sys.exit(2)

s.sendall(req.encode())
s.settimeout(4)
try:
    buf = s.recv(400)
except Exception as e:
    print('%s:%d%s  RECV-FAIL  %s' % (host, port, path, e))
    sys.exit(3)
finally:
    s.close()

txt = buf.decode('latin1')
head = txt.split('\r\n\r\n')[0]
lines = head.split('\r\n')
print('%s:%d%s  ->  %s' % (host, port, path, lines[0]))
for ln in lines[1:]:
    low = ln.lower()
    if low.startswith(('upgrade:', 'connection:', 'sec-websocket-accept:')):
        print('    ' + ln)
