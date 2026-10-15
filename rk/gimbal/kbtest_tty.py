#!/usr/bin/env python3
"""用伪终端(pty)驱动 gimbal_keyctrl.py，验证真实 TTY 下的方向键/回零/Ctrl+C 路径。

    python3 kbtest_tty.py [--port /dev/ttyACM0] [--with-zero-set]

默认只按一次 Ctrl+空格（验证二次确认提示），不会真的写入零点；
加 --with-zero-set 才会按两次（会改写并保存零点，慎用）。
"""
import os
import pty
import sys
import time

PORT = sys.argv[sys.argv.index('--port') + 1] if '--port' in sys.argv else '/dev/ttyACM0'
LOG = '/tmp/kbc_tty.log'
KEYS = [(b'\x1b[C', 0.6),   # →  Yaw 正向
        (b'\x1b[A', 0.6),   # ↑  Pitch 正向
        (b' ', 0.15),       # 空格：停止（第一次）
        (b' ', 6.0),        # 空格：双击 → ctrl angle 0 0 回零，等它到位
        (b'\x00', 1.0),     # Ctrl+空格：第一次，应只提示再按一次确认
        (b'\x03', 0.0)]     # Ctrl+C 退出
if '--with-zero-set' in sys.argv:
    KEYS.insert(-1, (b'\x00', 1.5))     # 第二次 Ctrl+空格：真的写零点
if '--home-then-zero' in sys.argv:
    # 先双击空格回零并留足时间到位，再设零点：当前位置≈0°，写入影响最小
    KEYS = [(b' ', 0.15),   # 空格（第一次）
            (b' ', 14.0),   # 双击 → 回零，等它走到位
            (b'\x00', 1.5),  # Ctrl+空格 #1：仅提示确认
            (b'\x00', 1.5),  # Ctrl+空格 #2：真正执行 config zero_pos
            (b'\x03', 0.0)]  # Ctrl+C 退出

pid, fd = pty.fork()
if pid == 0:
    # stdin 保持 pty（走 termios raw 分支），stdout 改成文件（走逐行日志分支）
    os.dup2(os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644), 1)
    os.execv('/root/gimbal_keyctrl.py',
             ['gimbal_keyctrl.py', '--port', PORT, '--duration', '20'])
time.sleep(1.2)
for data, pause in KEYS:
    os.write(fd, data)
    time.sleep(pause)
try:
    while os.read(fd, 4096):
        pass
except OSError:
    pass
_, status = os.waitpid(pid, 0)
with open(LOG, encoding='utf-8', errors='replace') as handle:
    sys.stdout.write(handle.read())
print('child exit status: %d (code=%d)' % (status, status >> 8))
