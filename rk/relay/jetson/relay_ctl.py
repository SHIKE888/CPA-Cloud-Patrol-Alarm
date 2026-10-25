#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""relay_ctl —— 车端中继控制节点（网页通过 rosbridge 调这些 service）

服务（std_srvs/Trigger）：
  /relay/start_mapping      杀掉现有 launch，启动 mapping.launch（gmapping）
  /relay/save_map           保存地图到 ~/maps/map_<时间戳>，并记录当时机器人位姿
  /relay/start_navigation   杀掉现有 launch，用保存的地图启动 navigation.launch
  /relay/stop               停掉所有 launch（保留 master）

设计要点：
  * 自己保证 ROS master 独立存在（roscore 以独立 session 起），切换 launch 不会把 master 带走；
  * 切换 = pkill roslaunch + 重启，避免两个 launch 抢串口；
  * 位姿从 tf: map -> base_footprint 读取（建图/导航两种模式都有）。
"""
import json
import os
import subprocess
import time

import rospy
import rosgraph
import tf2_ros
import numpy as np
from geometry_msgs.msg import PoseStamped
from nav_msgs.msg import OccupancyGrid
from std_srvs.srv import Trigger, TriggerResponse

HOME = os.path.expanduser('~')
MAP_DIR = os.path.join(HOME, 'maps')
STATE_DIR = os.path.join(HOME, 'ros_relay')
STATE_FILE = os.path.join(STATE_DIR, 'last_pose.json')
LOG_DIR = '/tmp'

BUF = tf2_ros.Buffer()
LISTENER = None
POSE_PUB = None
MAP_PUB = None
MAP_MARGIN = 10          # 裁剪时向外多留的格数（0.05 m/格 → 0.5 m）
MAP_CB_N = 0
_LAST_MAP = None                    # 最后一次成功裁剪的地图对象，用于静止补发
_LAST_MAP_TS = 0.0                  # 上次收到新图的时间
MAP_DEBUG_LOG = '/tmp/relay_map.log'


def _log(name):
    return open(os.path.join(LOG_DIR, name), 'a')


def ensure_master(timeout=15.0):
    """确保有一个独立于 launch 的 ROS master。"""
    if rosgraph.is_master_online():
        return True
    subprocess.Popen(['roscore'], stdout=_log('roscore.log'),
                     stderr=subprocess.STDOUT, start_new_session=True)
    t0 = time.time()
    while time.time() - t0 < timeout:
        if rosgraph.is_master_online():
            rospy.loginfo('relay_ctl: started standalone roscore')
            return True
        time.sleep(0.5)
    return False


def kill_launches():
    for pat in ('roslaunch turn_on_wheeltec_robot',
                'roslaunch.*mapping.launch',
                'roslaunch.*navigation.launch'):
        subprocess.call(['pkill', '-f', pat])
    time.sleep(2.0)


# roslaunch 必须在 source 过工作空间的 shell 里跑，否则报
# RLException: [mapping.launch] is neither a launch file in package ...
WS_PREFIX = ('source /opt/ros/noetic/setup.bash; '
             'source $HOME/wheeltec_lidar/devel/setup.bash 2>/dev/null; '
             'source $HOME/wheeltec_robot/devel/setup.bash 2>/dev/null; ')


def launch(cmdline, logname):
    p = subprocess.Popen(['bash', '-c', WS_PREFIX + 'exec ' + cmdline],
                         stdout=_log(logname),
                         stderr=subprocess.STDOUT, start_new_session=True)
    rospy.loginfo('relay_ctl: launch %s pid=%d', cmdline, p.pid)
    return p


def current_pose(timeout=2.0):
    """map -> base_footprint，返回 dict 或 None。"""
    try:
        tr = BUF.lookup_transform('map', 'base_footprint', rospy.Time(0),
                                  rospy.Duration(timeout))
    except Exception as e:  # noqa: BLE001
        rospy.logwarn('relay_ctl: 取位姿失败: %s', e)
        return None
    t = tr.transform.translation
    q = tr.transform.rotation
    yaw = _yaw(q.x, q.y, q.z, q.w)
    return {'x': t.x, 'y': t.y, 'yaw': yaw}


def _yaw(x, y, z, w):
    import math
    return math.atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))


def save_state(pose, map_base):
    os.makedirs(STATE_DIR, exist_ok=True)
    data = {'map_base': map_base, 'pose': pose, 'time': time.time()}
    with open(STATE_FILE, 'w') as f:
        json.dump(data, f, indent=2)
    return data


def read_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:  # noqa: BLE001
        return {}


# ---------------- services ----------------

def srv_start_mapping(_req):
    if not ensure_master():
        return TriggerResponse(False, 'ROS master 起不来')
    kill_launches()
    reset_latched_map()          # 先把上一轮 latch 的图冲掉，否则页面看着像没重启
    launch('roslaunch turn_on_wheeltec_robot mapping.launch mapping_mode:=gmapping',
           'relay_mapping.log')
    return TriggerResponse(True, '已重新开始建图（gmapping），约 10-20 秒后 /map 有数据')


def srv_save_map(_req):
    if not rosgraph.is_master_online():
        return TriggerResponse(False, 'ROS master 不在线')
    os.makedirs(MAP_DIR, exist_ok=True)
    stamp = time.strftime('%Y%m%d_%H%M%S')
    base = os.path.join(MAP_DIR, 'map_%s' % stamp)

    pose = current_pose()
    try:
        rc = subprocess.call(['rosrun', 'map_server', 'map_saver', '-f', base],
                             timeout=40, stdout=_log('relay_mapsaver.log'),
                             stderr=subprocess.STDOUT)
    except subprocess.TimeoutExpired:
        return TriggerResponse(False, 'map_saver 超时（是否不在建图模式？）')
    if rc != 0 or not os.path.exists(base + '.yaml'):
        return TriggerResponse(False, 'map_saver 失败，见 /tmp/relay_mapsaver.log')

    data = save_state(pose, base)
    msg = '已保存 %s.yaml' % base
    if pose:
        msg += '；记录位姿 (%.2f, %.2f, %.1f°)' % (
            pose['x'], pose['y'], pose['yaw'] * 57.2958)
    rospy.loginfo('relay_ctl: %s', msg)
    return TriggerResponse(True, msg)


def srv_start_navigation(_req):
    st = read_state()
    yaml_path = (st.get('map_base') or '') + '.yaml'
    if not yaml_path or not os.path.exists(yaml_path):
        return TriggerResponse(False, '还没保存过地图，请先「保存建图」')
    if not ensure_master():
        return TriggerResponse(False, 'ROS master 起不来')
    kill_launches()
    launch('roslaunch turn_on_wheeltec_robot navigation.launch map_file:=%s' % yaml_path,
           'relay_navigation.log')
    return TriggerResponse(True, '正在启动导航（地图 %s），到位后用「设为当前位置」定初始位姿'
                           % os.path.basename(yaml_path))


def srv_stop(_req):
    kill_launches()
    return TriggerResponse(True, '已停止 launch')


def srv_last_pose(_req):
    """返回建图结束时记录的位姿（JSON 字符串放在 message 里）。"""
    st = read_state()
    if not st:
        return TriggerResponse(False, '{}')
    return TriggerResponse(True, json.dumps(st))


def publish_pose(_ev=None):
    import math
    pose = current_pose(timeout=0.25)
    if not pose or POSE_PUB is None:
        return
    msg = PoseStamped()
    msg.header.stamp = rospy.Time.now()
    msg.header.frame_id = 'map'
    msg.pose.position.x = pose['x']
    msg.pose.position.y = pose['y']
    msg.pose.position.z = 0.0
    half = pose['yaw'] / 2.0
    msg.pose.orientation.z = math.sin(half)
    msg.pose.orientation.w = math.cos(half)
    POSE_PUB.publish(msg)


def map_cb(msg):
    global MAP_CB_N
    try:
        _map_cb(msg)
    except Exception as e:  # noqa: BLE001
        rospy.logerr('map_cb error: %r', e)
        try:
            with open(MAP_DEBUG_LOG, 'a') as f:
                f.write('ERR %r\n' % (e,))
        except Exception:  # noqa: BLE001
            pass


def _map_cb(msg):
    """把 800x800 的全图裁成「已建图区域 + margin」，再发到 /relay/map。

    rosbridge 用 JSON 传 64 万个格子≈1.9 MB/帧，2.4G 链路吃不消；
    裁剪后通常只剩几万格（~100 KB），刷新就顺了。
    """
    global MAP_CB_N, _LAST_MAP, _LAST_MAP_TS
    if MAP_PUB is None:
        return
    w, h = msg.info.width, msg.info.height
    if w <= 0 or h <= 0:
        return
    a = np.asarray(msg.data, dtype=np.int8).reshape(h, w)
    mask = a >= 0
    known = int(mask.sum())
    MAP_CB_N += 1
    if MAP_CB_N % 10 == 1:
        try:
            with open(MAP_DEBUG_LOG, 'a') as f:
                f.write('#%d %dx%d known=%d\n' % (MAP_CB_N, w, h, known))
        except Exception:  # noqa: BLE001
            pass
    if known == 0:
        return
    xs = np.where(mask.any(axis=0))[0]
    ys = np.where(mask.any(axis=1))[0]
    x0 = max(0, int(xs[0]) - MAP_MARGIN)
    x1 = min(w, int(xs[-1]) + MAP_MARGIN + 1)
    y0 = max(0, int(ys[0]) - MAP_MARGIN)
    y1 = min(h, int(ys[-1]) + MAP_MARGIN + 1)

    res = msg.info.resolution
    out = OccupancyGrid()
    out.header = msg.header
    out.info = msg.info
    out.info.width = x1 - x0
    out.info.height = y1 - y0
    out.info.origin.position.x = msg.info.origin.position.x + x0 * res
    out.info.origin.position.y = msg.info.origin.position.y + y0 * res
    out.data = a[y0:y1, x0:x1].flatten().tolist()
    _LAST_MAP = out                 # 缓存，给静止补发用
    _LAST_MAP_TS = time.time()
    MAP_PUB.publish(out)


def _map_keepalive(_evt):
    """车静止时 SLAM 不出新图，这里把最后一帧按 1Hz 补发。

    为什么需要：gmapping / hector 的 /map 都是事件驱动的 —— 车不动、激光
    场景也不变时，它们可以几秒甚至几十秒不发一条消息。网页那边表现为
    “图冻住了”、Hz 掉到 0。这里只要 0.9s 没收到新图，就把缓存那帧重发。
    """
    if _LAST_MAP is None or MAP_PUB is None:
        return
    if time.time() - _LAST_MAP_TS < 0.9:
        return                      # 刚收到过新图，不用补
    MAP_PUB.publish(_LAST_MAP)


def reset_latched_map():
    """冲掉 latch 住的旧地图。

    /relay/map 是 latch=True：重新建图后，在 gmapping 发出第一帧新图之前，
    任何新订阅者（包括刚刷新过的网页）都会立即收到上一轮那张图，
    看起来就像“点了开始建图没反应”。
    这里发一帧 1x1 的占位图，前端识别到尺寸 <= 1 就把画面清空。
    """
    if MAP_PUB is None:
        return
    _LAST_MAP = None                # 同时清掉补发缓存，否则 keepalive 会把旧图又发回来
    m = OccupancyGrid()
    m.header.stamp = rospy.Time.now()
    m.header.frame_id = 'map'
    m.info.resolution = 0.05
    m.info.width = 1
    m.info.height = 1
    m.info.origin.orientation.w = 1.0
    m.data = [-1]
    MAP_PUB.publish(m)


def main():
    global LISTENER, POSE_PUB, MAP_PUB
    rospy.init_node('relay_ctl', anonymous=False)
    LISTENER = tf2_ros.TransformListener(BUF)
    POSE_PUB = rospy.Publisher('/relay/robot_pose', PoseStamped, queue_size=5)
    rospy.Timer(rospy.Duration(0.1), publish_pose)
    MAP_PUB = rospy.Publisher('/relay/map', OccupancyGrid, queue_size=1, latch=True)
    rospy.Subscriber('/map', OccupancyGrid, map_cb, queue_size=1)
    # SLAM 静止不出图时，按 1Hz 补发最后一帧，保证网页始终有数据流
    rospy.Timer(rospy.Duration(1.0), _map_keepalive)

    for name, cb in (('start_mapping', srv_start_mapping),
                     ('save_map', srv_save_map),
                     ('start_navigation', srv_start_navigation),
                     ('last_pose', srv_last_pose),
                     ('stop', srv_stop)):
        rospy.Service('/relay/' + name, Trigger, cb)
    rospy.loginfo('relay_ctl ready: /relay/{start_mapping,save_map,start_navigation,last_pose,stop}')
    rospy.spin()


if __name__ == '__main__':
    main()
