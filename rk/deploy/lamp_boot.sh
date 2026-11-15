#!/bin/sh
# 由 udev 规则在 CH340 枚举时触发：尽快点亮四色灯的蓝灯。
#
# ★ 必须后台执行：udev 的 RUN+= 会阻塞该设备的其它事件处理，不能在里面跑
#   会重试 20 秒的 Python。
# ★ mipi-webstream 已经在跑（比如设备被重新插拔）时直接退出，不要去抢它
#   正在使用的串口。

if /bin/systemctl is-active --quiet mipi-webstream 2>/dev/null; then
    exit 0
fi

/usr/bin/setsid /opt/miniforge3/envs/mlk-ov/bin/python \
    /root/rk/deploy/lamp_boot.py >/dev/null 2>&1 &

exit 0
