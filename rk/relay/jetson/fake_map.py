#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发布一张假的 latched OccupancyGrid 到 /map，用来验证网页渲染链路（不动底盘/雷达）。

用法（车端）：
    source /opt/ros/noetic/setup.bash
    python3 tools/fake_map.py            # 发一张 10m x 10m 的假地图后常驻
    python3 tools/fake_map.py --once     # 发一次就退出
"""
import argparse
import random

import rospy
from nav_msgs.msg import OccupancyGrid


def build(width=200, height=200, res=0.05):
    g = OccupancyGrid()
    g.header.frame_id = 'map'
    g.info.resolution = res
    g.info.width = width
    g.info.height = height
    g.info.origin.position.x = -width * res / 2.0
    g.info.origin.position.y = -height * res / 2.0
    g.info.origin.orientation.w = 1.0

    cx, cy = width // 2, height // 2
    data = []
    for y in range(height):
        for x in range(width):
            v = 0
            if x < 3 or y < 3 or x > width - 4 or y > height - 4:
                v = 100                                   # 外墙
            elif (x - cx) ** 2 + (y - cy) ** 2 < (width // 6) ** 2:
                v = 100                                   # 中间圆环障碍
            elif 40 < x < 60 and 120 < y < 160:
                v = 100                                   # 矩形障碍
            elif random.random() < 0.004:
                v = 100                                   # 噪点
            elif (x + y) % 40 == 0:
                v = -1                                    # 未知条纹
            data.append(v)
    g.data = data
    return g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--once', action='store_true')
    a = ap.parse_args()

    rospy.init_node('fake_map', anonymous=True)
    pub = rospy.Publisher('/map', OccupancyGrid, queue_size=1, latch=True)
    rospy.sleep(0.5)
    g = build()
    pub.publish(g)
    rospy.loginfo('fake map published: %dx%d @ %.3f m/px',
                  g.info.width, g.info.height, g.info.resolution)
    if a.once:
        return
    # 周期重发：rosbridge 的 WebSocket 订阅可能晚于 latched 那一瞬，重发更稳
    rospy.Timer(rospy.Duration(1.0), lambda _e: pub.publish(g))
    rospy.spin()


if __name__ == '__main__':
    main()
