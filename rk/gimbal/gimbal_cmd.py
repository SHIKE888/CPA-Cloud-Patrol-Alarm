#!/usr/bin/env python3
"""直接在 QGimbal 控制台上执行命令并原样打印回显（诊断用）。

    python3 gimbal_cmd.py [--port /dev/ttyACM0] "status" "diag" "config --list"

失败回显（failed: ...）会照常打印，不会当成异常中断，
方便查看固件拒绝原因。默认不加参数时只读 status/diag。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gimbal_keyctrl import Link                      # noqa: E402


def main():
    args = sys.argv[1:]
    port = args[args.index('--port') + 1] if '--port' in args else '/dev/ttyACM0'
    if '--port' in args:
        index = args.index('--port')
        del args[index:index + 2]
    commands = args or ['status', 'diag']
    link = Link(port, 115200, 1.0)
    try:
        for command in commands:
            print('>>> %s' % command, flush=True)
            try:
                print(link.command(command), flush=True)
            except Exception as error:
                print('[执行异常] %s' % error, flush=True)
    finally:
        link.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
