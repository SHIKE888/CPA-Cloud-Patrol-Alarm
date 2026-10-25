#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""直接连 rosbridge，发 subscribe 看能否收到 /map 数据（判断是后端还是前端问题）。

用法： python tools/probe_rosbridge.py --url ws://192.168.0.100:9090 --topic /map --type nav_msgs/OccupancyGrid
"""
import argparse
import base64
import json
import os
import socket
import struct
import sys
import time


def handshake(sock, host, port, path):
    key = base64.b64encode(os.urandom(16)).decode()
    req = ('GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n'
           'Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n'
           'Sec-WebSocket-Version: 13\r\n\r\n' % (path, host, port, key))
    sock.sendall(req.encode())
    buf = b''
    while b'\r\n\r\n' not in buf:
        c = sock.recv(4096)
        if not c:
            raise RuntimeError('closed during handshake')
        buf += c
    head, _, rest = buf.partition(b'\r\n\r\n')
    return head.decode('latin-1'), rest


def send_text(sock, text):
    data = text.encode()
    mask = os.urandom(4)
    n = len(data)
    hdr = bytearray([0x81])
    if n < 126:
        hdr.append(0x80 | n)
    elif n < 65536:
        hdr.append(0x80 | 126)
        hdr += struct.pack('>H', n)
    else:
        hdr.append(0x80 | 127)
        hdr += struct.pack('>Q', n)
    hdr += mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    sock.sendall(bytes(hdr) + masked)


def read_frame(sock, buf):
    while len(buf) < 2:
        buf += sock.recv(65536)
    b0, b1 = buf[0], buf[1]
    op = b0 & 0x0F
    ln = b1 & 0x7F
    pos = 2
    if ln == 126:
        while len(buf) < 4:
            buf += sock.recv(65536)
        ln = struct.unpack('>H', buf[2:4])[0]
        pos = 4
    elif ln == 127:
        while len(buf) < 10:
            buf += sock.recv(65536)
        ln = struct.unpack('>Q', buf[2:10])[0]
        pos = 10
    while len(buf) < pos + ln:
        buf += sock.recv(65536)
    return op, buf[pos:pos + ln], buf[pos + ln:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--url', default='ws://192.168.0.100:9090')
    ap.add_argument('--topic', default='/map')
    ap.add_argument('--type', default='nav_msgs/OccupancyGrid')
    ap.add_argument('--seconds', type=float, default=6)
    a = ap.parse_args()

    u = a.url.replace('ws://', '')
    hp, _, path = u.partition('/')
    host, _, port = hp.partition(':')
    port = int(port or 9090)
    path = '/' + path if path else '/'

    s = socket.create_connection((host, port), 8)
    s.settimeout(3)
    head, buf = handshake(s, host, port, path)
    print('握手:', head.split('\r\n')[0])
    send_text(s, json.dumps({'op': 'subscribe', 'id': 'p1',
                             'topic': a.topic, 'type': a.type,
                             'throttle_rate': 1000, 'queue_length': 1}))
    print('已订阅', a.topic, a.type)

    got = 0
    deadline = time.time() + a.seconds
    while time.time() < deadline:
        try:
            op, payload, buf = read_frame(s, buf)
        except socket.timeout:
            continue
        if op != 0x1:
            continue
        try:
            msg = json.loads(payload.decode('utf-8', 'replace'))
        except Exception:
            # 兼容 rosbridge 的压缩/分片形式
            continue
        o = msg.get('op')
        if o == 'publish':
            got += 1
            m = msg.get('msg', {})
            info = m.get('info', {})
            print('publish #%d: %sx%s @ %s, data_len=%s' % (
                got, info.get('width'), info.get('height'),
                info.get('resolution'), len(m.get('data', []))))
            if got >= 2:
                break
        elif o == 'status':
            print('status:', msg.get('msg'), msg.get('level'))
        elif o == 'service_response':
            print('service_response:', str(msg)[:120])
        else:
            print('op=%s %s' % (o, str(msg)[:120]))

    print('收到 publish 次数 =', got)
    s.close()
    return 0 if got else 3


if __name__ == '__main__':
    sys.exit(main())
