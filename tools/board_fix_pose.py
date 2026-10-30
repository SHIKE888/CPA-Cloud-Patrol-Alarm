#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""车端「点云和地图对不上」时，用激光与地图做一次全局匹配，算出车在地图里的真实位姿，
可选下发 /initialpose。

背景（2026-10-30）：
    last_pose.json 里记的是「保存建图那一刻」的位姿。只要之后车被推过/开过，
    拿它当初始位姿必然错位；而且 AMCL 会把发过去的位姿原样回显（看 TF 永远
    "对得上"），页面上只表现为点云和墙错开。所以这里不信任任何记录，
    直接拿当前激光点云去地图里搜。

做法：
    · 取一帧 /scan + /map，用 base->laser 静态变换把激光点投到 base 系；
    · 在整张地图范围内粗搜 (x, y, yaw)（0.3 m / 15°），再精搜（0.05 m / 2°）；
    · 打分 = 激光点落在占据格(3x3 邻域)里的比例，>0.35 认为可信；
    · 可信就发 /initialpose，等 4 秒回读 AMCL 收敛后的位姿与命中率。

用法（车上）：
    . /opt/ros/noetic/setup.bash
    export ROS_MASTER_URI=http://127.0.0.1:11311
    python3 ~/ros_relay/fix_pose.py            # 算完并下发
    python3 ~/ros_relay/fix_pose.py --no-pub   # 只算不下发

实测（2026-10-30 17:4x）：
    当前位姿 (-0.450, 0.586, -104 deg) 命中率 0.006   <- last_pose.json 的旧位姿，完全错
    搜到     (2.850, 0.950, -15 deg)   命中率 0.829   <- 车其实在这儿
    下发后 AMCL = (2.863, 0.949, -15.1 deg) 命中率 0.840，点云和墙对齐
"""
import math
import sys

import numpy as np
import rospy
import tf2_ros
from sensor_msgs.msg import LaserScan
from nav_msgs.msg import OccupancyGrid
from geometry_msgs.msg import PoseWithCovarianceStamped

NO_PUB = '--no-pub' in sys.argv
MIN_SCORE = 0.35          # 低于这个命中率不敢下发


def yaw_of(q):
    return math.atan2(2.0 * (q.w * q.z + q.x * q.y), 1.0 - 2.0 * (q.y * q.y + q.z * q.z))


def lookup(buf, target, source, tries=30):
    for _ in range(tries):
        try:
            return buf.lookup_transform(target, source, rospy.Time(0), rospy.Duration(0.5))
        except Exception:      # noqa: BLE001  TF 刚开始缓冲时会 Extrapolation
            rospy.sleep(0.3)
    return None


def main():
    rospy.init_node('fix_pose', anonymous=True)
    buf = tf2_ros.Buffer()
    tf2_ros.TransformListener(buf)

    scan = rospy.wait_for_message('/scan', LaserScan, timeout=10)
    grid = rospy.wait_for_message('/map', OccupancyGrid, timeout=10)

    tl = lookup(buf, 'base_footprint', scan.header.frame_id)
    if tl is None:
        print('拿不到 base_footprint -> %s 的 TF' % scan.header.frame_id)
        return 1
    lx, ly, lyaw = (tl.transform.translation.x, tl.transform.translation.y,
                    yaw_of(tl.transform.rotation))

    r = np.asarray(scan.ranges, dtype=np.float64)
    a = scan.angle_min + np.arange(r.size) * scan.angle_increment
    ok = np.isfinite(r) & (r >= scan.range_min) & (r <= scan.range_max)
    r, a = r[ok], a[ok]
    px, py = r * np.cos(a), r * np.sin(a)
    bx = lx + px * math.cos(lyaw) - py * math.sin(lyaw)
    by = ly + px * math.sin(lyaw) + py * math.cos(lyaw)

    W, H, res = grid.info.width, grid.info.height, grid.info.resolution
    ox, oy = grid.info.origin.position.x, grid.info.origin.position.y
    print('map origin=(%.2f, %.2f) size=%.1f x %.1f m  点数=%d'
          % (ox, oy, W * res, H * res, r.size))

    occ = np.asarray(grid.data, dtype=np.int16).reshape(H, W)
    ob = (occ > 50)
    o3 = ob.copy()
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            if dx or dy:
                o3 |= np.roll(np.roll(ob, dx, axis=0), dy, axis=1)

    def score(x, y, th):
        c, s = math.cos(th), math.sin(th)
        mx = x + bx * c - by * s
        my = y + bx * s + by * c
        cx = ((mx - ox) / res).astype(np.int32)
        cy = ((my - oy) / res).astype(np.int32)
        inb = (cx >= 0) & (cx < W) & (cy >= 0) & (cy < H)
        if inb.sum() < 50:
            return -1.0
        return float(o3[cy[inb], cx[inb]].mean())

    tp = lookup(buf, 'map', 'base_footprint')
    if tp is not None:
        cur = (tp.transform.translation.x, tp.transform.translation.y, yaw_of(tp.transform.rotation))
        print('当前位姿 (%.3f, %.3f, %.1f deg)  命中率 %.3f'
              % (cur[0], cur[1], cur[2] * 57.2958, score(*cur)))

    best = (-1.0, 0.0, 0.0, 0.0)
    for x in np.arange(ox + 0.3, ox + W * res, 0.3):
        for y in np.arange(oy + 0.3, oy + H * res, 0.3):
            for th in np.radians(np.arange(-180, 180, 15)):
                v = score(x, y, th)
                if v > best[0]:
                    best = (v, x, y, th)
    print('粗搜 (%.3f) at (%.2f, %.2f, %.0f deg)'
          % (best[0], best[1], best[2], best[3] * 57.2958))

    b2 = best
    for x in np.arange(best[1] - 0.35, best[1] + 0.36, 0.05):
        for y in np.arange(best[2] - 0.35, best[2] + 0.36, 0.05):
            for th in np.radians(np.arange(-8, 8.1, 2)) + best[3]:
                v = score(x, y, th)
                if v > b2[0]:
                    b2 = (v, x, y, th)
    print('精搜 (%.3f) at (%.3f, %.3f, %.1f deg)'
          % (b2[0], b2[1], b2[2], b2[3] * 57.2958))

    if b2[0] < MIN_SCORE:
        print('=> 最好也只有 %.2f（< %.2f），不敢下发。请确认车在已建图区域里、激光没被挡。'
              % (b2[0], MIN_SCORE))
        return 2

    if NO_PUB:
        print('=> --no-pub，只报了最优位姿，没有下发')
        return 0

    pub = rospy.Publisher('/initialpose', PoseWithCovarianceStamped, queue_size=1)
    rospy.sleep(0.5)
    m = PoseWithCovarianceStamped()
    m.header.frame_id = 'map'
    m.header.stamp = rospy.Time.now()
    m.pose.pose.position.x = b2[1]
    m.pose.pose.position.y = b2[2]
    m.pose.pose.orientation.z = math.sin(b2[3] / 2.0)
    m.pose.pose.orientation.w = math.cos(b2[3] / 2.0)
    m.pose.covariance = [0.05, 0, 0, 0, 0, 0,
                         0, 0.05, 0, 0, 0, 0,
                         0, 0, 0, 0, 0, 0,
                         0, 0, 0, 0, 0, 0,
                         0, 0, 0, 0, 0, 0,
                         0, 0, 0, 0, 0, 0.02]
    for _ in range(4):
        pub.publish(m)
        rospy.sleep(0.3)
    print('已发 /initialpose -> (%.2f, %.2f, %.0f deg)' % (b2[1], b2[2], b2[3] * 57.2958))
    rospy.sleep(4)
    t2 = lookup(buf, 'map', 'base_footprint')
    if t2 is not None:
        p2 = (t2.transform.translation.x, t2.transform.translation.y, yaw_of(t2.transform.rotation))
        print('AMCL 现在 = (%.3f, %.3f, %.1f deg)  命中率 %.3f'
              % (p2[0], p2[1], p2[2] * 57.2958, score(*p2)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
