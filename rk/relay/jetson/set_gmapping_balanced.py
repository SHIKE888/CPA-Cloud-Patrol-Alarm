#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 algorithm_gmapping.launch 调成「清晰 + 能跟手」的平衡参数。

用 Python 按 param 名精确改写 value，不用 sed（引号会被 shell 吃掉，
历史上把 value="1.0" 改成过 value=.0.5. 这种非法值）。

用法:  python3 set_gmapping_balanced.py [--dry-run]
"""
import io
import os
import re
import shutil
import sys

P = ('/home/wheeltec/wheeltec_robot/src/turn_on_wheeltec_robot/'
     'launch/include/algorithm_gmapping.launch')

# 目标值。取舍说明见文件末尾。
#
# 【实测教训】计算量 = 地图格数 × 粒子数，gmapping 是单线程的：
#    delta=0.05, ±12m(480×480=23万格), 20 粒子 = 460 万格次
#      -> 单核 100%，/map 只有 0.079 Hz（12 秒一帧）
#    现在降到 ±7m(280×280=7.8万格) × 8 粒子 = 63 万格次
#      -> 预期 ~1 Hz。要更清晰只能缩范围或减粒子，没有别的办法。
NEW = {
    # —— 刷新率：静止也更新 ——
    # temporalUpdate 是 gmapping 唯一的“不动也更新”开关，但它需要单帧
    # processScan 够快才转得起来，所以必须和下面的算量一起降。
    'temporalUpdate':      '0.3',    # -1.0 -> 0.3   静止时也尝试每 0.3s 更新
    'map_update_interval': '0.25',   # 发图上限 ~4Hz
    # —— 灵敏度：走两步就有新图 ——
    # 【不要调太小】0.02 时一点点噪声、一点点转动就触发一次建图更新，
    # 位姿的微小抖动被无限次叠加，地图就变成发散的扇形条纹。
    # 回到原厂 0.05。
    'linearUpdate':        '0.05',
    'angularUpdate':       '0.05',
    # —— 清晰度 ——
    'delta':               '0.05',   # 5cm/格（保持，这是消失锯齿的关键）
    # —— 粒子数：这是位姿精度的命根子 ——
    # 试过 8：/map 也能到 0.386 Hz、不卡了，但地图变成放射状条纹 ——
    # 粒子太少时似然峰很平，每帧选出的位姿都在抖，扫描层叠起来就糊了。
    # 20 是速度与精度的平衡点（原厂默认 30）。
    'particles':           '20',
    # —— 匹配阈值：60 太严 ——
    # 原厂默认 0。设 60 时车静止（激光场景几乎不变）经常达不到分数，
    # processScan 直接 return，地图就不更新了——这是“不动不更新”的
    # 第二个原因。放回 30。
    'minimumScore':        '30',
    'iterations':          '5',
    'lstep':               '0.04',
    'astep':               '0.04',
    # —— 量程 ——
    'maxUrange':           '5.5',
    'maxRange':            '6.0',
    # —— 地图边界：必须让 (max-min)/delta 恰好等于 2 的幂 ——
    #
    # 【踩过的坑】之前给 ±7（需 14m/0.05 = 280 格），gmapping 内部的
    # HierarchicalArray2D 按 2^n 对齐，实际产出 256 格，但 origin 仍写成
    # -7.0  ->  地图真实覆盖 -7.0 ~ +5.8，中心偏了 0.6 m。表现就是
    # "机器人不在图中央"，而且保存的地图、导航目标点全都整体错 0.6 m。
    #
    # 256 x 0.05 = 12.8 m  ->  取 ±6.4，中心正好是 (0,0)=建图起点。
    # 换 delta 时记得同步：格数 = (xmax-xmin)/delta 必须是 2 的幂。
    'xmin':                '-6.4',
    'ymin':                '-6.4',
    'xmax':                '6.4',
    'ymax':                '6.4',
}


def main():
    dry = '--dry-run' in sys.argv
    if not os.path.exists(P):
        sys.exit('launch not found: %s' % P)

    src = io.open(P, encoding='utf-8').read()
    missing = []

    for k, v in NEW.items():
        pat = re.compile(r'(<param\s+name="%s"\s+value=")[^"]*(")' % re.escape(k))
        src, n = pat.subn(lambda m, v=v: m.group(1) + v + m.group(2), src)
        if n == 0:
            missing.append(k)
        print('%-22s -> %-6s  %s' % (k, v, 'ok' if n else 'MISSING'))

    if missing:
        print('\nWARNING: 以下参数在文件里没匹配到（可能未定义）：%s' % ', '.join(missing))

    if dry:
        print('\n[dry-run] 未写入')
        return

    bak = P + '.bak_balanced'
    if not os.path.exists(bak):
        shutil.copy2(P, bak)
        print('\n备份 -> %s' % bak)
    io.open(P, 'w', encoding='utf-8').write(src)
    print('已写入 %s' % P)


if __name__ == '__main__':
    main()
