#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Foxglove WebSocket 协议探测：验证 foxglove_bridge 可用并列出 channel。

用法：
    python tools/foxglove_probe.py --url ws://192.168.0.100:8765 --seconds 5

协议要点（foxglove.websocket.v1）：
  - 握手需 Sec-WebSocket-Protocol: foxglove.websocket.v1
  - 服务端二进制帧 = 1B opcode + 4B LE 长度 + JSON 载荷
  - op=1 serverInfo, op=2 status, op=3 advertise, op=4 unadvertise,
    op=5 advertiseServices, op=6 advertiseSubscribe? （以官方为准）
"""
import argparse
import base64
import json
import os
import socket
import struct
import sys
import time

SUBPROTO = 'foxglove.websocket.v1'


def ws_handshake(sock, host, port, path):
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        'GET %s HTTP/1.1\r\n'
        'Host: %s:%d\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: %s\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Protocol: %s\r\n'
        '\r\n' % (path, host, port, key, SUBPROTO)
    )
    sock.sendall(req.encode())
    buf = b''
    while b'\r\n\r\n' not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError('handshake closed: %r' % buf)
        buf += chunk
    head, _, rest = buf.partition(b'\r\n\r\n')
    return head.decode('latin-1'), rest


def read_frame(sock, buf):
    while len(buf) < 2:
        buf += sock.recv(4096)
    b0, b1 = buf[0], buf[1]
    opcode = b0 & 0x0F
    masked = b1 & 0x80
    ln = b1 & 0x7F
    pos = 2
    if ln == 126:
        while len(buf) < pos + 2:
            buf += sock.recv(4096)
        ln = struct.unpack('>H', buf[pos:pos + 2])[0]
        pos += 2
    elif ln == 127:
        while len(buf) < pos + 8:
            buf += sock.recv(4096)
        ln = struct.unpack('>Q', buf[pos:pos + 8])[0]
        pos += 8
    if masked:
        while len(buf) < pos + 4:
            buf += sock.recv(4096)
        pos += 4
    while len(buf) < pos + ln:
        buf += sock.recv(4096)
    payload = buf[pos:pos + ln]
    return opcode, payload, buf[pos + ln:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--url', default='ws://192.168.0.100:8765')
    ap.add_argument('--seconds', type=float, default=5.0)
    ap.add_argument('--debug', action='store_true')
    a = ap.parse_args()

    u = a.url.replace('ws://', '')
    hostport, _, path = u.partition('/')
    host, _, port = hostport.partition(':')
    port = int(port or 8765)
    path = '/' + path if path else '/'

    sock = socket.create_connection((host, port), 8)
    sock.settimeout(3)
    head, buf = ws_handshake(sock, host, port, path)
    print('== HTTP 握手响应 ==')
    for line in head.split('\r\n')[:4]:
        print('  ' + line)
    if ' 101 ' not in head.split('\r\n')[0]:
        print('!! 未升级为 WebSocket')
        return 1

    print('== 协议帧 ==')
    deadline = time.time() + a.seconds
    channels = {}
    while time.time() < deadline:
        try:
            opcode, payload, buf = read_frame(sock, buf)
        except socket.timeout:
            continue
        if opcode == 0x8:
            print('  server closed')
            break
        if opcode not in (0x1, 0x2):
            print('  raw ws opcode=%d len=%d' % (opcode, len(payload)))
            continue

        # foxglove_bridge 0.8.x 实测：协商 v1 后仍用 text 帧发纯 JSON（无二进制头）
        if opcode == 0x1:
            txt = payload.decode('utf-8', 'replace')
            if a.debug:
                print('  text len=%d head=%r' % (len(txt), txt[:72]))
            try:
                msg = json.loads(txt)
            except Exception:
                continue
            if 'channels' in msg:
                for ch in msg['channels']:
                    channels[ch['id']] = ch
                    print('  advertise: id=%s topic=%s enc=%s schema=%s' % (
                        ch['id'], ch.get('topic'), ch.get('encoding'),
                        ch.get('schemaName') or (ch.get('schema') or '')[:24]))
            elif 'capabilities' in msg:
                print('  serverInfo: capabilities=%s' % ','.join(msg['capabilities']))
            elif 'services' in msg:
                print('  advertiseServices: %d' % len(msg['services']))
            elif 'op' in msg:
                print('  %s: %s' % (msg['op'], json.dumps(msg, ensure_ascii=False)[:140]))
            continue

        # 二进制头格式（部分版本/客户端）：1B op + 4B LE len + JSON
        if len(payload) < 5:
            continue
        op = payload[0]
        ln = struct.unpack('<I', payload[1:5])[0]
        body = payload[5:5 + ln]
        try:
            msg = json.loads(body.decode('utf-8', 'replace'))
        except Exception:
            continue
        if op == 3:
            for ch in msg.get('channels', []):
                channels[ch['id']] = ch
                print('  advertise(bin): id=%s topic=%s' % (ch['id'], ch.get('topic')))
        else:
            print('  op%d: %s' % (op, json.dumps(msg, ensure_ascii=False)[:140]))

    print('== 小结 ==')
    print('  channel 数 = %d' % len(channels))
    sock.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
