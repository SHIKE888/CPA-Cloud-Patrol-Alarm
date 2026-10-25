#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""客观校验：激光点变换到 map 系后，有多少落在 /map 的占据栅格上。

用法（车端）： source /opt/ros/noetic/setup.bash && python3 tools/scan_check.py

同时对比两种假设：
  A) 直接按 laser 系画（旧逻辑，不做 base->laser 变换）
  B) 正确变换到 map 系
哪一组命中率（占据/未知）高，说明哪种画法对。
"""
import math

import rospy
import tf2_ros
from nav_msgs.msg import OccupancyGrid
from sensor_msgs.msg import LaserScan

BUF = tf2_ros.Buffer()


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


def hit_rate(grid, pts):
    """返回 (占据率, 未知率, 平均占用度)"""
    w, h = grid.info.width, grid.info.height
    res = grid.info.resolution
    ox, oy = grid.info.origin.position.x, grid.info.origin.position.y
    d = grid.data
    occ = unk = total = 0
    acc = 0.0
    for x, y in pts:
        mx = int((x - ox) / res)
        my = int((y - oy) / res)
        if mx < 0 or my < 0 or mx >= w or my >= h:
            continue
        v = d[my * w + mx]
        total += 1
        if v < 0:
            unk += 1
        elif v > 50:
            occ += 1
            acc += v
    if not total:
        return 0.0, 0.0, 0.0
    return occ / total, unk / total, (acc / occ if occ else 0.0)


def main():
    rospy.init_node('scan_check', anonymous=True)
    tf2_ros.TransformListener(BUF)
    rospy.sleep(1.5)

    scan = rospy.wait_for_message('/scan', LaserScan, timeout=10)
    grid = rospy.wait_for_message('/map', OccupancyGrid, timeout=10)

    laser_pts = []
    for i, r in enumerate(scan.ranges):
        if not (scan.range_min <= r <= scan.range_max):
            continue
        a = scan.angle_min + i * scan.angle_increment
        laser_pts.append((r * math.cos(a), r * math.sin(a)))
    if not laser_pts:
        print('没有有效激光点')
        return

    try:
        tr = BUF.lookup_transform('map', scan.header.frame_id, rospy.Time(0),
                                  rospy.Duration(3.0))
    except Exception as e:  # noqa: BLE001
        print('取变换失败: %s' % e)
        return

    t = tr.transform.translation
    yaw = yaw_of(tr.transform.rotation)
    c, s = math.cos(yaw), math.sin(yaw)
    map_pts = [(t.x + x * c - y * s, t.y + x * s + y * c) for x, y in laser_pts]

    print('scan frame = %s, 点数 = %d' % (scan.header.frame_id, len(laser_pts)))
    print('map->%s: t=(%.3f, %.3f) yaw=%.1f°' % (
        scan.header.frame_id, t.x, t.y, yaw * 57.2958))

    a_occ, a_unk, a_v = hit_rate(grid, laser_pts)
    b_occ, b_unk, b_v = hit_rate(grid, map_pts)
    print('A) 直接按 laser 系查地图 : 占据 %.1f%%  未知 %.1f%%  平均占用 %.0f' % (
        a_occ * 100, a_unk * 100, a_v))
    print('B) 变换到 map 系   查地图 : 占据 %.1f%%  未知 %.1f%%  平均占用 %.0f' % (
        b_occ * 100, b_unk * 100, b_v))
    print('结论：%s' % ('B 正确（需做 base->laser 变换）' if b_occ > a_occ + 0.02 else
                     ('A 正确（无需变换）' if a_occ > b_occ + 0.02 else '两者接近，需人工判断')))


if __name__ == '__main__':
    main()
