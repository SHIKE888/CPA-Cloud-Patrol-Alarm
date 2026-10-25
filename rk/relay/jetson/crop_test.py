#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""复现 relay_ctl 的地图裁剪逻辑，定位为什么 /relay/map 不出数据。"""
import numpy as np
import rospy
from nav_msgs.msg import OccupancyGrid


def main():
    rospy.init_node('crop_test', anonymous=True)
    m = rospy.wait_for_message('/map', OccupancyGrid, timeout=15)
    print('data.len=%d  w=%d h=%d res=%.3f' % (
        len(m.data), m.info.width, m.info.height, m.info.resolution))
    a = np.asarray(m.data, dtype=np.int8).reshape(m.info.height, m.info.width)
    mask = a >= 0
    print('已知格数=%d / %d' % (int(mask.sum()), mask.size))
    print('取值样例:', a.ravel()[::max(1, a.size // 10)][:10].tolist())
    if mask.any():
        xs = np.where(mask.any(axis=0))[0]
        ys = np.where(mask.any(axis=1))[0]
        print('bbox x[%d..%d] y[%d..%d]' % (xs[0], xs[-1], ys[0], ys[-1]))
        sub = a[ys[0]:ys[-1] + 1, xs[0]:xs[-1] + 1]
        print('裁剪后 %dx%d = %d 格（原 %d 格，减少 %.1f%%）' % (
            sub.shape[1], sub.shape[0], sub.size, a.size,
            100.0 * (1 - sub.size / a.size)))


if __name__ == '__main__':
    main()
