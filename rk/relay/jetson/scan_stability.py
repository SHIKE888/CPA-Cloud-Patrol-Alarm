#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检查 /scan 稳定性：车静止时连续两帧的距离差。
若中位差 > 5cm，说明雷达数据本身在抖，建图必炸。

用法（车端）： source /opt/ros/noetic/setup.bash && python3 tools/scan_stability.py
"""
import rospy
from sensor_msgs.msg import LaserScan

MSGS = []


def cb(m):
    MSGS.append(m)


def main():
    rospy.init_node('scan_stability', anonymous=True)
    rospy.Subscriber('/scan', LaserScan, cb)
    while len(MSGS) < 3 and not rospy.is_shutdown():
        rospy.sleep(0.05)

    a, b = MSGS[0], MSGS[-1]
    print('帧1: n=%d  angle=[%.2f, %.2f] inc=%.5f  scan_time=%.3f' % (
        len(a.ranges), a.angle_min, a.angle_max, a.angle_increment, a.scan_time))
    print('帧2: n=%d  angle=[%.2f, %.2f] inc=%.5f  scan_time=%.3f' % (
        len(b.ranges), b.angle_min, b.angle_max, b.angle_increment, b.scan_time))

    n = min(len(a.ranges), len(b.ranges))
    diffs = []
    for i in range(n):
        ra, rb = a.ranges[i], b.ranges[i]
        if not (a.range_min <= ra <= a.range_max):
            continue
        if not (b.range_min <= rb <= b.range_max):
            continue
        diffs.append(abs(ra - rb))
    if not diffs:
        print('没有有效点')
        return
    diffs.sort()
    k = len(diffs)
    print('有效点 %d / %d' % (k, n))
    print('距离差: 中位 %.3f m  p90 %.3f m  最大 %.3f m' % (
        diffs[k // 2], diffs[int(k * 0.9)], diffs[-1]))
    med = diffs[k // 2]
    print('判定: %s' % ('雷达稳定（可以建图）' if med < 0.05 else
                       ('抖动偏大，建图会漂' if med < 0.15 else '严重抖动，先查雷达/转速')))


if __name__ == '__main__':
    main()
