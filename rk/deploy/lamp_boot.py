# -*- coding: utf-8 -*-
"""上电瞬间点亮四色灯的蓝灯。

为什么单独一个脚本：
  mipi-webstream 要等到 userspace 启动 18 秒后才起来，而 USB 在 kernel 阶段
  （约 3 秒）就枚举完了。用户希望**上电 2~4 秒**就能看到蓝灯，表示
  "板子已上电、正在启动"，所以由 udev 规则在 CH340 枚举时直接触发这里。

设计要点：
  · 尽力而为：失败一律静默返回 0，绝不阻塞开机。
  · 发完立刻 close()，把 USB 接口还回去 —— 否则 mipi-webstream 起来时
    claim 不到设备，灯会卡在蓝色不动。
  · 本内核没有 ch341 驱动，走 alarm_light.Ch340Port 的用户态实现。
"""

import sys
import time

sys.path.insert(0, "/root/rk/web")

REG_BLUE = 0x03
STATE_ON = 0x01


def _frame(reg, state, mid=0x01):
    from alarm_light import modbus_crc16
    body = bytes([mid, 0x05, 0x00, reg, state, 0x00])
    c = modbus_crc16(body)
    return body + bytes([c & 0xFF, (c >> 8) & 0xFF])


def main():
    try:
        from alarm_light import Ch340Port
    except Exception:                    # 依赖缺失 / 代码还没部署
        return 0

    port = None
    # USB 枚举刚完成时接口未必马上能 claim，重试最多 20 秒
    for _ in range(40):
        try:
            port = Ch340Port(9600)
            break
        except Exception:                # noqa: BLE001
            time.sleep(0.5)
    if port is None:
        return 0

    try:
        port.write(_frame(REG_BLUE, STATE_ON))
        port.flush()
        time.sleep(0.05)
        try:
            port.read(8)                 # 吃掉 Modbus 回显
        except Exception:                # noqa: BLE001
            pass
    except Exception:                    # noqa: BLE001
        pass
    finally:
        port.close()                     # ★ 必须释放，否则 mipi-webstream 抢不到
    return 0


if __name__ == "__main__":
    sys.exit(main())
