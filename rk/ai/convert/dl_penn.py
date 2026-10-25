# -*- coding: utf-8 -*-
"""Penn Action 分段并发下载器（带断点续传 + 实时进度文件）。

为什么不用 curl 循环：upenn 服务器**限单连接 ~23 KB/s**，必须多连接；而
PowerShell 的 Start-Job 在多次会话之间会丢，无法可靠续传。这里用一个进程
管 N 条连接，每条连接自己负责一个连续区间，断了就按 Range 从断点续。

    python dl_penn.py --url <url> --out D:\\datasets\\Penn_Action.tar.gz --n 32
"""
import argparse
import json
import os
import ssl
import sys
import threading
import time
import urllib.request

CHUNK = 1 << 20          # 每次读 1MB
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'


def head_size(url, ctx):
    req = urllib.request.Request(url, method='HEAD', headers={'User-Agent': UA})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
        return int(r.headers['Content-Length'])


class Part(threading.Thread):
    def __init__(self, url, path, start, end, ctx, stat):
        threading.Thread.__init__(self)
        self.daemon = True
        # ❗ 不能叫 self.start：会覆盖 Thread.start() 方法
        self.url, self.path, self.s0, self.e0 = url, path, start, end
        self.ctx, self.stat = ctx, stat
        self.stop = False

    def run(self):
        while not self.stop:
            have = os.path.getsize(self.path) if os.path.exists(self.path) else 0
            total = self.e0 - self.s0 + 1
            if have >= total:
                return
            from_ = self.s0 + have
            try:
                req = urllib.request.Request(
                    self.url, headers={'User-Agent': UA,
                                       'Range': 'bytes=%d-%d' % (from_, self.e0)})
                with urllib.request.urlopen(req, context=self.ctx, timeout=60) as r:
                    with open(self.path, 'ab') as fp:
                        while not self.stop:
                            buf = r.read(CHUNK)
                            if not buf:
                                break
                            fp.write(buf)
                            fp.flush()
                            self.stat.add(len(buf))
            except Exception:                              # noqa: BLE001
                time.sleep(2)                              # 断了就续，不退出
            time.sleep(0.2)


class Stat(object):
    def __init__(self, total):
        self.total = total
        self.done = 0
        self.lock = threading.Lock()
        self.t0 = time.time()

    def add(self, n):
        with self.lock:
            self.done += n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--url', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--n', type=int, default=32, help='并发连接数')
    ap.add_argument('--progress', default='')
    ap.add_argument('--timeout', type=float, default=0.0, help='秒；0=不限')
    args = ap.parse_args()

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE      # 本机 schannel 吊销检查离线，直接跳过校验
    total = head_size(args.url, ctx)
    print('总大小 %.2f GB，%d 路并发' % (total / 1e9, args.n))

    n = args.n
    chunk = -(-total // n)
    parts = []
    for i in range(n):
        s = i * chunk
        e = min(s + chunk - 1, total - 1)
        if s > total - 1:
            break
        path = args.out + '.p%d' % i
        # 已有完成的分片直接复用
        if os.path.exists(path) and os.path.getsize(path) >= (e - s + 1):
            parts.append((path, s, e))
            continue
        parts.append((path, s, e))

    stat = Stat(total)
    for path, s, e in parts:
        have = os.path.getsize(path) if os.path.exists(path) else 0
        stat.done += have
    stats = Stat(total)
    stats.done = stat.done

    threads = [Part(args.url, p, s, e, ctx, stats) for p, s, e in parts]
    for t in threads:
        t.start()

    prog = args.progress or (args.out + '.progress.json')
    t0 = time.time()
    while True:
        alive = [t for t in threads if t.is_alive()]
        el = time.time() - t0
        rate = 0.0
        prev = stats.done
        time.sleep(2.0)
        rate = (stats.done - prev) / 2.0
        frac = stats.done / float(total)
        eta = (total - stats.done) / rate if rate > 1 else -1
        info = {'done_mb': round(stats.done / 1e6, 1),
                'total_mb': round(total / 1e6, 1),
                'pct': round(frac * 100, 1),
                'rate_mb_s': round(rate / 1e6, 2),
                'eta_s': int(eta) if eta > 0 else -1,
                'threads': len(alive), 'elapsed_s': int(el)}
        try:
            with open(prog, 'w', encoding='utf-8') as fp:
                json.dump(info, fp)
        except Exception:                                  # noqa: BLE001
            pass
        sys.stdout.write('\r%5.1f%%  %8.1f/%.1f MB  %.2f MB/s  ETA %s s  活连接 %d   ' %
                         (info['pct'], info['done_mb'], info['total_mb'],
                          info['rate_mb_s'], info['eta_s'], info['threads']))
        sys.stdout.flush()
        if not alive:
            break
        if args.timeout and el > args.timeout:
            for t in threads:
                t.stop = True
            break

    print('\n合并分片...')
    with open(args.out, 'wb') as out:
        for path, s, e in parts:
            with open(path, 'rb') as fp:
                while True:
                    buf = fp.read(CHUNK * 4)
                    if not buf:
                        break
                    out.write(buf)
    size = os.path.getsize(args.out)
    print('%s  %.2f GB  期望 %.2f GB  %s'
          % (args.out, size / 1e9, total / 1e9, 'OK' if size == total else '大小不符!'))
    if size == total:
        for path, s, e in parts:
            try:
                os.remove(path)
            except OSError:
                pass


if __name__ == '__main__':
    main()
