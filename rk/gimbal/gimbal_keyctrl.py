#!/usr/bin/env python3
"""QGimbal 键盘方向键控制（在开发板上运行，SSH 终端可直接用方向键）。

用法:
    ./gimbal_keyctrl.py --port /dev/ttyACM0 [--speed 10] [--accel 20] [--duration 0]

按键:
    ← / →        Yaw  正向 / 反向（已按实物观察反向；--yaw-sign -1 可再翻回来）
    ↑ / ↓        Pitch 正向 / 反向
    a / d        Yaw  正向 / 反向（备用，方向键识别不了时用）
    w / s        Pitch 正向 / 反向（备用）
    空格          两轴目标速度归零（保持使能，不退出）
    e            切换匀加减速：开=按 accel/stop-accel 斜坡；关=目标速度阶跃直接生效
    双击空格      ctrl angle 0 0 回零点（运动中空格/方向键可接管）
    Ctrl+空格     把当前位置设为 Zero 点（config zero_pos，会写入 Flash）
                  固件要求先失能，脚本会自动 disable → 写零点 → 重新 enable
    ESC           同空格，停止
    q / Ctrl+C    退出：先 ctrl speed 0 0，再 disable 并核对 diag

注意: config zero_pos 是标定命令（改写“零在哪里”并保存），默认需要在
      --zero-confirm-ms（默认 5s）内再按一次 Ctrl+空格才会真的执行，
      传 --zero-confirm-ms 0 可关闭二次确认。

启动: version -> disable_stability -> disable -> diag(确认失能) -> enable
退出: ctrl speed 0 0 -> disable（最多 3 次）-> diag 确认两轴 enabled=0
      确认失败打印告警并以退出码 2 结束。

注意: 串口被独占（TIOCEXCL），运行前请关掉其他串口客户端/网页上位机。
      方向键按住时终端会重复发送按键，脚本按“最后一次按键”计时；
      起手用 --release-ms（默认 700ms，需大于终端的 key repeat 初始延迟，
      通常 500ms），一旦检测到按键重复就改用 --repeat-release-ms（默认 250ms），
      所以松手后能很快停住；超时后目标速度降为 0（按 --stop-accel 斜坡降落）。
      若你的终端仍出现“速度先降后升”，把 --release-ms 调大（如 1000）。
"""
import argparse
import math
import os
import re
import select
import signal
import sys
import time

import termios

PROMPT = re.compile(r'QGimbal:/\$\s*$')
REJECT = re.compile(r'failed|Command not Found|STALE|\bnan\b|\binf\b', re.I)
ANGLE = r'^\s+%s\s*:\s*yaw:([-+0-9.eE]+)\s+(?:rad|rpm),\s*pitch:([-+0-9.eE]+)'
KEYMAP = {
    # Yaw 按实物观察左右反向：按 → 发负速度，按 ← 发正速度
    'left': (0, +1), 'right': (0, -1),
    'up': (1, +1), 'down': (1, -1),
    'a': (0, +1), 'd': (0, -1),
    'w': (1, +1), 's': (1, -1),
}


class Link:
    """非阻塞串口读写 + “发命令等提示符”封装。"""

    def __init__(self, port, baud, timeout):
        import fcntl
        import struct
        self.timeout = timeout
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            fcntl.ioctl(self.fd, termios.TIOCEXCL)
            attr = termios.tcgetattr(self.fd)
            attr[0] = attr[1] = attr[3] = 0
            attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            attr[4] = attr[5] = getattr(termios, 'B%d' % baud)
            attr[6][termios.VMIN] = attr[6][termios.VTIME] = 0
            termios.tcsetattr(self.fd, termios.TCSANOW, attr)
            fcntl.ioctl(self.fd, termios.TIOCMBIS, struct.pack('I', termios.TIOCM_DTR))
        except BaseException:
            os.close(self.fd)
            raise

    def _chunk(self, timeout):
        if not select.select([self.fd], [], [], timeout)[0]:
            return ''
        try:
            data = os.read(self.fd, 4096)
        except BlockingIOError:
            return ''
        if not data:
            # tty 在 VMIN=0 下 read() 返回 0 只表示“当前没有数据”，不是断开；
            # 稍微让一下，避免 select 一直报可读时变成忙等。
            time.sleep(0.001)
            return ''
        return data.decode('ascii', errors='replace')

    def _drain(self):
        """丢掉设备已经发出、但还没被读走的残留字节，避免上一条命令的回显被误判。"""
        while select.select([self.fd], [], [], 0)[0]:
            try:
                if not os.read(self.fd, 4096):
                    break
            except BlockingIOError:
                break

    def command(self, cmd, expect=None):
        termios.tcflush(self.fd, termios.TCIFLUSH)
        self._drain()
        payload = (cmd + '\n').encode('ascii')
        deadline = time.monotonic() + self.timeout
        while payload:
            if not select.select([], [self.fd], [], max(0, deadline - time.monotonic()))[1]:
                raise TimeoutError('写超时: ' + cmd)
            try:
                payload = payload[os.write(self.fd, payload):]
            except BlockingIOError:
                pass
        reply = ''
        while time.monotonic() < deadline:
            reply += self._chunk(min(.02, max(0, deadline - time.monotonic())))
            if REJECT.search(reply):
                raise RuntimeError('%s 被拒绝: %s' % (cmd, reply.strip().replace('\n', ' | ')))
            if PROMPT.search(reply):
                if expect and not re.search(expect, reply):
                    raise RuntimeError('%s 回复异常: %s'
                                       % (cmd, reply.strip().replace('\n', ' | ')))
                return reply
        raise TimeoutError('回复超时: ' + cmd)

    def close(self):
        os.close(self.fd)


class Gimbal:
    """QGimbal 控制台命令（参数顺序固定 Yaw、Pitch）。"""

    def __init__(self, link):
        self.link = link

    def version(self):
        return self.link.command('version', r'Firmware target Run')

    def enable(self):
        return self.link.command('enable', r'QGimbal enabled')

    def disable(self):
        return self.link.command('disable', r'QGimbal disabled')

    def no_stability(self):
        return self.link.command('disable_stability', r'stability control disabled')

    def diag(self, disabled=False):
        reply = self.link.command('diag', r'Target=Run Fault=0 ')
        if 'Owner=USB' not in reply or len(re.findall(r'enabled=[01] error=0 ', reply)) != 2:
            raise RuntimeError('diag 状态异常: %s' % reply.strip().replace('\n', ' | '))
        if disabled and len(re.findall(r'enabled=0 error=0 ', reply)) != 2:
            raise RuntimeError('失能未确认: %s' % reply.strip().replace('\n', ' | '))
        return reply

    def speed(self, yaw, pitch):
        return self.link.command('ctrl speed %.6f %.6f' % (yaw, pitch), r'Setting control Y:')

    def angle(self, yaw, pitch):
        return self.link.command('ctrl angle %.6f %.6f' % (yaw, pitch))

    def zero_pos(self):
        """把当前双轴编码器角设为关节零点并触发保存（标定命令）。"""
        return self.link.command('config zero_pos')

    def telemetry(self):
        """返回 ((yaw_angle, pitch_angle), (yaw_speed, pitch_speed))，缺失项为 None。"""
        reply = self.link.command('status', r'Gimbal Status:')
        out = []
        for field in ('Angle', 'Speed'):
            match = re.search(ANGLE % field, reply, re.M)
            out.append(tuple(map(float, match.groups())) if match else None)
        return out


class Keyboard:
    """把 stdin 切成按键事件；支持方向键的 CSI（ESC [ X）与 SS3（ESC O X）序列。"""

    def __init__(self, tty):
        self.fd = sys.stdin.fileno()
        self.tty = tty
        self.saved = None
        self.buf = b''
        self.escape_at = None
        if tty:
            self.saved = termios.tcgetattr(self.fd)
            attr = termios.tcgetattr(self.fd)
            attr[0] &= ~(termios.ICRNL | termios.INLCR | termios.IXON)
            attr[3] &= ~(termios.ICANON | termios.ECHO | termios.IEXTEN)
            attr[6][termios.VMIN] = attr[6][termios.VTIME] = 0
            termios.tcsetattr(self.fd, termios.TCSANOW, attr)

    def restore(self):
        if self.saved is not None:
            try:
                termios.tcsetattr(self.fd, termios.TCSANOW, self.saved)
            except Exception:
                pass

    def read_keys(self, timeout):
        if select.select([self.fd], [], [], timeout)[0]:
            try:
                data = os.read(self.fd, 64)
            except (BlockingIOError, OSError):
                data = b''
            if data:
                self.buf += data
        return self._parse(time.monotonic())

    def _parse(self, now):
        keys = []
        while self.buf:
            if self.buf[0] != 0x1b:
                keys.append(chr(self.buf[0]))
                self.buf = self.buf[1:]
                continue
            if len(self.buf) == 1:                      # 可能是方向键前缀，等下一批字节
                if self.escape_at is None:
                    self.escape_at = now
                elif now - self.escape_at > 0.15:
                    self.buf = b''
                    self.escape_at = None
                    keys.append('esc')
                break
            self.escape_at = None
            if self.buf[1:2] in (b'[', b'O'):
                end = 2
                while end < len(self.buf) and not 0x40 <= self.buf[end] <= 0x7e:
                    end += 1
                if end >= len(self.buf):
                    break                               # 序列还没收全
                final = chr(self.buf[end])
                self.buf = self.buf[end + 1:]
                keys.append({'A': 'up', 'B': 'down', 'C': 'right', 'D': 'left'}.get(final, 'other'))
            else:                                        # Alt+键等，丢弃
                self.buf = self.buf[2:]
                keys.append('other')
        return keys


def ramp(current, target, dt, accel, stop_accel=None):
    rate = accel if abs(target) >= abs(current) else (stop_accel or accel)
    step = rate * max(0.0, dt)
    if target > current:
        return min(target, current + step)
    return max(target, current - step)


def fmt(value, unit=''):
    return '  --   ' if value is None else '%+7.2f%s' % (value, unit)


def safe_disable(gimbal, poll, attempts):
    for index in range(attempts):
        try:
            gimbal.speed(0, 0)
        except Exception:
            pass
        try:
            gimbal.disable()
            time.sleep(poll)
            gimbal.diag(disabled=True)
            print('Both axes disabled.')
            return True
        except Exception as error:
            print('失能重试 %d/%d 失败: %s' % (index + 1, attempts, error))
    print('DISABLE NOT CONFIRMED. 请立即检查云台/电源。')
    return False


def re_enable(gimbal, poll, attempts):
    """写 Flash 期间固件会回 failed: storage transaction active，使能需要重试。"""
    error = None
    for _ in range(attempts):
        try:
            diag = gimbal.diag()
            if len(re.findall(r'enabled=1 error=0 ', diag)) != 2:
                gimbal.enable()
            gimbal.speed(0, 0)
            return True
        except Exception as failure:
            error = failure
            time.sleep(poll)
    print('恢复使能失败（已重试 %d 次）: %s' % (attempts, error), flush=True)
    return False


class Session:
    """手动速度控制 + 双击空格回零（ctrl angle 0 0）+ Ctrl+空格设零点（config zero_pos）。"""

    def __init__(self, args, gimbal, keyboard):
        self.args = args
        self.gimbal = gimbal
        self.keyboard = keyboard
        self.poll = args.poll_ms / 1000
        self.release = args.release_ms / 1000
        self.telemetry_period = args.telemetry_ms / 1000
        self.speed = abs(args.speed)
        self.accel = abs(args.accel)
        self.stop_accel = abs(args.stop_accel) or 3 * self.accel
        self.double_space = args.double_space_ms / 1000
        self.zero_confirm = args.zero_confirm_ms / 1000
        self.sign = [args.yaw_sign, args.pitch_sign]
        self.smooth = not args.no_ramp
        self.repeat_release = args.repeat_release_ms / 1000
        self.repeat_gap = args.repeat_gap_ms / 1000
        self.busy_window = 0.4
        self.last_key = [0.0, 0.0]
        self.activity = 0.0
        self.target = [0.0, 0.0]
        self.hold = [0.0, 0.0]
        self.current = [0.0, 0.0]
        self.telemetry = [None, None]
        self.note = '就绪'
        self.plain = not sys.stdout.isatty()
        self.homing = False
        self.home_deadline = 0.0
        self.home_next = 0.0
        self.space_at = 0.0
        self.zero_at = 0.0
        self.last = time.monotonic()
        self.next_telemetry = self.last

    def stop_motion(self, note=None):
        self.target = [0.0, 0.0]
        self.hold = [0.0, 0.0]
        if note:
            self.note = note

    def handle(self, keys, now):
        """处理按键，返回 True 表示用户请求退出。"""
        for key in keys:
            if key in ('q', 'Q'):
                return True
            if key == '\x00':                       # Ctrl+Space（NUL）
                self.request_zero(now)
            elif key in (' ', 'esc'):
                if key == ' ' and self.space_at and now - self.space_at <= self.double_space:
                    self.space_at = 0.0
                    self.start_home(now)
                else:
                    self.space_at = now if key == ' ' else 0.0
                    self.homing = False
                    self.stop_motion('已停止（保持使能）')
            elif key in ('e', 'E'):
                self.smooth = not self.smooth
                self.note = '匀加减速: %s' % ('开' if self.smooth else '关（阶跃）')
            elif key in KEYMAP:
                self.homing = False
                axis, direction = KEYMAP[key]
                direction *= self.sign[axis]
                # 自适应松开窗口：终端刚开始重复发送时用长窗口，
                # 已进入重复（间隔很短）后改用短窗口，松手就能很快停。
                gap = now - self.last_key[axis] if self.last_key[axis] else 1.0
                window = self.repeat_release if gap <= self.repeat_gap else self.release
                self.last_key[axis] = now
                self.activity = now
                self.target[axis] = direction * self.speed
                self.hold[axis] = now + window
                self.note = ('Yaw' if axis == 0 else 'Pitch') + \
                            (' +' if direction > 0 else ' -')
        return False

    def start_home(self, now):
        self.homing = True
        self.stop_motion('回零中…（空格/方向键可接管）')
        self.current = [0.0, 0.0]
        self.gimbal.speed(0, 0)
        self.gimbal.angle(0, 0)
        self.home_deadline = now + self.args.home_timeout
        self.home_next = now + self.telemetry_period

    def update_home(self, now):
        if now >= self.home_next:
            self.home_next = now + self.telemetry_period
            self.gimbal.angle(0, 0)                 # 角度目标持续有效，定期重申
            self.telemetry = self.gimbal.telemetry()
        angles, rates = self.telemetry
        settled = angles and max(map(abs, angles)) <= self.args.home_tol_rad
        if settled and (not rates or max(map(abs, rates)) <= self.args.home_settled_rpm):
            self.homing = False
            self.gimbal.speed(0, 0)
            self.note = '回零完成'
        elif now > self.home_deadline:
            self.homing = False
            self.gimbal.speed(0, 0)
            self.note = '回零超时，已切回速度模式'

    def request_zero(self, now):
        if not self.zero_confirm:
            self.set_zero()
            return
        if self.zero_at and now - self.zero_at <= self.zero_confirm:
            self.zero_at = 0.0
            self.set_zero()
            return
        self.zero_at = now
        self.note = '再按一次 Ctrl+空格 确认设零点（%.0f 秒内）' % (self.args.zero_confirm_ms / 1000)

    def set_zero(self):
        self.homing = False
        self.stop_motion('设置零点中…')
        self.current = [0.0, 0.0]
        print('\n写零点需要先失能（固件要求 disable + 反馈/IMU 就绪）；失能后 Pitch 可能'
              '因重力轻微下垂，会以下垂后的姿态为零点。', flush=True)
        try:
            self.gimbal.speed(0, 0)
            self.gimbal.disable()
            self.gimbal.diag(disabled=True)
            reply = self.gimbal.zero_pos()
            text = ' | '.join(line.strip() for line in reply.splitlines() if line.strip())
            print('config zero_pos 回显: %s' % text, flush=True)
            self.note = '零点已按当前姿态设置并保存'
        except Exception as error:
            print('设置零点失败: %s' % error, flush=True)
            self.note = '设置零点失败（见回显）'
        finally:
            if not re_enable(self.gimbal, self.args.store_retry_ms / 1000,
                             self.args.store_attempts):
                raise RuntimeError('零点保存后未能恢复使能')

    def line(self):
        angles, _ = self.telemetry
        return (' Yaw %s  Pitch %s  |  cmd %+6.1f / %+6.1f rpm  |  %s  |  %s '
                % (fmt(math.degrees(angles[0]) if angles else None, '°'),
                   fmt(math.degrees(angles[1]) if angles else None, '°'),
                   self.current[0], self.current[1],
                   'ramp' if self.smooth else 'step', self.note))

    def show(self):
        if self.plain:
            print(self.line().strip(), flush=True)
        else:
            sys.stdout.write('\r\033[K' + self.line())
            sys.stdout.flush()

    def run(self):
        start = self.last = time.monotonic()
        self.next_telemetry = start
        while self.args.duration <= 0 or time.monotonic() - start < self.args.duration:
            if self.handle(self.keyboard.read_keys(self.poll), time.monotonic()):
                return
            now = time.monotonic()
            if self.zero_at and now - self.zero_at > self.zero_confirm:
                self.zero_at = 0.0
                self.note = '已取消设零点（确认超时）'
            dt = now - self.last
            self.last = now
            refresh = now >= self.next_telemetry
            if self.homing:
                self.update_home(now)
            else:
                for axis in (0, 1):
                    if now > self.hold[axis]:
                        self.target[axis] = 0.0
                for axis in (0, 1):
                    if self.smooth:
                        self.current[axis] = ramp(self.current[axis], self.target[axis],
                                                  dt, self.accel, self.stop_accel)
                    else:
                        self.current[axis] = self.target[axis]
                self.gimbal.speed(self.current[0], self.current[1])
                if refresh:
                    # 操作期间降低遥测频率（status 回显较长，会拖慢按键响应）
                    busy = now - self.activity <= self.busy_window
                    self.next_telemetry = now + self.telemetry_period * (1.5 if busy else 1.0)
                    self.telemetry = self.gimbal.telemetry()
            if refresh or not self.plain:
                self.show()


def main():
    parser = argparse.ArgumentParser(
        description='QGimbal 键盘控制（SSH 终端可用方向键、空格、Ctrl+空格）')
    parser.add_argument('--port', required=True, help='/dev/ttyACM0 或 /dev/serial/by-id/...')
    parser.add_argument('--speed', type=float, default=10.0, help='按键目标速度 rpm（默认 10）')
    parser.add_argument('--accel', type=float, default=40.0, help='速度斜坡 rpm/s（默认 40）')
    parser.add_argument('--release-ms', type=float, default=700.0,
                        help='按键“起手”后的松开判定窗口（默认 700ms）。终端长按方向键时'
                             '前约 500ms 不发送重复键，设小了会出现“速度先降后升”的抽动')
    parser.add_argument('--repeat-release-ms', type=float, default=200.0,
                        help='已进入按键重复后使用的松开判定窗口（默认 200ms，越小停得越快）')
    parser.add_argument('--repeat-gap-ms', type=float, default=150.0,
                        help='两次按键间隔小于该值就认为终端在重复发送（默认 150ms）')
    parser.add_argument('--stop-accel', type=float, default=0.0,
                        help='松手减速斜坡 rpm/s，0=自动取 3×accel（默认 0）')
    parser.add_argument('--poll-ms', type=float, default=10.0, help='控制周期（默认 10ms）')
    parser.add_argument('--telemetry-ms', type=float, default=200.0, help='遥测刷新周期（默认 200ms）')
    parser.add_argument('--reply-timeout-ms', type=float, default=800.0, help='命令回复超时（默认 800ms）')
    parser.add_argument('--double-space-ms', type=float, default=400.0,
                        help='双击空格回零的判定窗口（默认 400ms）')
    parser.add_argument('--home-tol-rad', type=float, default=0.02,
                        help='回零到位判定误差 rad（默认 0.02）')
    parser.add_argument('--home-settled-rpm', type=float, default=0.3,
                        help='回零到位判定速度 rpm（默认 0.3）')
    parser.add_argument('--home-timeout', type=float, default=20.0,
                        help='回零超时秒数（默认 20）')
    parser.add_argument('--zero-confirm-ms', type=float, default=5000.0,
                        help='Ctrl+空格 设零点的二次确认窗口，0=不确认（默认 5000）')
    parser.add_argument('--store-attempts', type=int, default=10,
                        help='写 Flash 后恢复使能的重试次数（默认 10）')
    parser.add_argument('--store-retry-ms', type=float, default=300.0,
                        help='写 Flash 后恢复使能的重试间隔（默认 300ms）')
    parser.add_argument('--yaw-sign', type=float, default=1.0,
                        help='Yaw 方向系数，1=保持键位映射，-1=左右再翻一次（默认 1）')
    parser.add_argument('--pitch-sign', type=float, default=1.0,
                        help='Pitch 方向系数，1=保持键位映射，-1=上下再翻一次（默认 1）')
    parser.add_argument('--no-ramp', action='store_true',
                        help='启动时就关闭匀加减速（同按 e；目标速度阶跃生效）')
    parser.add_argument('--duration', type=float, default=0.0, help='运行秒数，0 表示直到手动退出')
    args = parser.parse_args()
    for name in ('speed', 'accel', 'release_ms', 'poll_ms', 'telemetry_ms',
                 'reply_timeout_ms', 'double_space_ms', 'home_tol_rad',
                 'home_settled_rpm', 'home_timeout', 'store_attempts', 'store_retry_ms',
                 'repeat_release_ms', 'repeat_gap_ms'):
        if getattr(args, name) <= 0:
            parser.error('--%s 必须为正数' % name.replace('_', '-'))
    if args.zero_confirm_ms < 0:
        parser.error('--zero-confirm-ms 不能为负')
    if args.stop_accel < 0:
        parser.error('--stop-accel 不能为负')
    if args.yaw_sign == 0 or args.pitch_sign == 0:
        parser.error('--yaw-sign / --pitch-sign 不能为 0')

    link = gimbal = keyboard = None
    code = 0
    try:
        link = Link(args.port, 115200, args.reply_timeout_ms / 1000)
        gimbal = Gimbal(link)
        print('连接 %s，准备云台…' % args.port, flush=True)
        gimbal.version()
        gimbal.no_stability()
        gimbal.disable()
        gimbal.diag(disabled=True)
        gimbal.enable()
        if not re_enable(gimbal, args.poll_ms / 1000, args.store_attempts):
            raise RuntimeError('启动时无法进入速度控制')
        keyboard = Keyboard(sys.stdin.isatty())
        print('就绪: ←→ Yaw，↑↓ Pitch，空格停止，双击空格回零，Ctrl+空格设零点，'
              'e 匀加减速开关，q / Ctrl+C 退出并失能（备用键 a/d/w/s）', flush=True)
        Session(args, gimbal, keyboard).run()
    except (Exception, KeyboardInterrupt) as error:
        message = str(error) or type(error).__name__
        if isinstance(error, KeyboardInterrupt):
            message = '用户中断'
        print('\nStopped: %s' % message, flush=True)
        code = 1
    finally:
        if keyboard:
            keyboard.restore()
        if link:
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            try:
                if gimbal and not safe_disable(gimbal, args.poll_ms / 1000, 3):
                    code = 2
            finally:
                link.close()
        if sys.stdout.isatty():
            print()
    return code


def _on_sigterm(signum, frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, _on_sigterm)
    sys.exit(main())
