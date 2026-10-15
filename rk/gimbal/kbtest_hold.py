#!/usr/bin/env python3
"""模拟终端“长按方向键”，复现/验证速度是否抖动。

真实终端的长按序列：按下立即发 1 次按键 → 约 500ms（key repeat delay）
后才开始每 ~30ms 重复发送（key repeat rate）。

    python3 kbtest_hold.py [--port /dev/ttyACM0] [--release-ms 300]
                          [--delay 0.5] [--repeat 0.03] [--count 20] [--key right]
                          [--linger 0.6]
"""
import os
import pty
import sys
import time

KEYS = {'right': b'\x1b[C', 'left': b'\x1b[D', 'up': b'\x1b[A', 'down': b'\x1b[B'}


def option(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


PORT = option('--port', '/dev/ttyACM0')
LOG = '/tmp/kbc_hold.log'
DELAY = float(option('--delay', '0.5'))
REPEAT = float(option('--repeat', '0.03'))
COUNT = int(option('--count', '20'))
LINGER = float(option('--linger', '0.6'))
EXTRA = option('--extra', '')
RELEASE = option('--release-ms', '')
KEY = KEYS[option('--key', 'right')]

pid, fd = pty.fork()
if pid == 0:
    # stdin 保持 pty（termios raw 分支），stdout 落文件（逐行日志）
    os.dup2(os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644), 1)
    argv = ['gimbal_keyctrl.py', '--port', PORT, '--duration', '30',
            '--telemetry-ms', '50', '--speed', '10']
    if RELEASE:
        argv += ['--release-ms', RELEASE]
    if EXTRA:
        argv += EXTRA.split()
    os.execv('/root/gimbal_keyctrl.py', argv)
time.sleep(1.0)
os.write(fd, KEY)                 # 按下：终端立即发一次
time.sleep(DELAY)                 # key repeat 初始延迟
for _ in range(COUNT):            # 按住后的重复
    os.write(fd, KEY)
    time.sleep(REPEAT)
time.sleep(LINGER)                # 松手，观察减速停止
os.write(fd, b'\x03')             # Ctrl+C 退出
try:
    while os.read(fd, 4096):
        pass
except OSError:
    pass
_, status = os.waitpid(pid, 0)
with open(LOG, encoding='utf-8', errors='replace') as handle:
    lines = [line for line in handle.read().splitlines() if '|' in line]
print('release-ms=%s delay=%.2f repeat=%.2f count=%d' % (RELEASE or 'default', DELAY, REPEAT, COUNT))
for line in lines:
    print(line)
print('child exit code=%d' % (status >> 8))
