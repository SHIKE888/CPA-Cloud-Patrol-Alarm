#!/bin/sh
# 模拟键盘输入，用于没有 TTY 的自动化自测：
#   右、右（Yaw 正向按住两次）→ 上（Pitch 正向）→ 空格（停止）→ q（退出）
printf '\033[C'; sleep 0.5
printf '\033[C'; sleep 0.5
printf '\033[A'; sleep 0.8
printf ' ';     sleep 0.5
printf 'q'
