#!/bin/sh
# 验证 e 键切换匀加减速：
#   → 按住升速到位 → 按 e 关闭斜坡 → 按 ← 应立即阶跃到 -10rpm（无斜坡）
printf '\033[C'; sleep 0.6
printf 'e';      sleep 0.35
printf '\033[D'; sleep 0.45
printf 'q'
