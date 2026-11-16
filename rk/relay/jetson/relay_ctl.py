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
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import rospy
import rosgraph
import rosnode
import tf2_ros
import numpy as np
from geometry_msgs.msg import PoseStamped
from nav_msgs.msg import OccupancyGrid, Odometry
from std_msgs.msg import Float32
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


# ---------------- 底盘保活（让 /PowerVoltage 一直在）----------------
# 2026-11-16 用户要求：不点「开始建图 / 进入导航」时，网页顶栏也要能显示车电量。
# /PowerVoltage 只有底盘节点 wheeltec_robot 在跑时才发，而它平时只有
# mapping.launch / navigation.launch 才带起来。所以这里在"没任务"的空隙里
# 补一个单底盘 launch；点建图/导航时 kill_launches() 会先杀掉它、并静默 60s。
# 注意：底盘节点常驻 = 电机使能、/cmd_vel 有人订阅；没有指令时输出 0 速度，
# 不会自己走，但任何误发指令都会让车动。
_BASE_SUPPRESS_UNTIL = 0.0
_LAST_BASE_TRY = 0.0

# ---------------- 电量 HTTP 端点（给板子读，绕开 rosbridge）----------------
# 2026-11-16 实测车端 rosbridge(Autobahn 17.10.1) 对板子的自写 WS 客户端
# 只记日志「Subscribed」但一字节不回（浏览器连同一端口却正常），定位不动。
# 所以这里自己开个 20 行的 HTTP 端点，板子 urllib 轮询即可，链路可控。
VOLT_PORT = 9097
_VOLT = {'v': None, 'ts': 0.0}
_BASE_ALIVE = False          # 由 keep_base_alive 定时刷新，HTTP 线程只读

# ---------------- 车辆运动 / 模式（给板子上的四色灯用）----------------
# 用户要求（2026-11-16）：车真在运动时绿灯暴闪，优先级高；
# 处于巡检（导航）模式下静止时绿灯慢闪。
# 运动判据用 /odom 的 twist：底盘自己报的速度，比看 cmd_vel 真实
# （遥控有看门狗、导航有减速段，cmd_vel 非零不等于真在动）。
# 原地转也算动，所以把角速度折算一个等效线速度。
_MOTION = {'v': 0.0, 'w': 0.0, 'ts': 0.0}
MODE = {'name': 'idle'}          # idle / mapping / navigation
_NAV_UP = False                  # 导航栈是否在跑，定时刷新（HTTP 线程只读）
MOVE_V = 0.02                    # m/s，低于这个当静止
MOVE_W = 0.05                    # rad/s
_ODOM_TTL = 2.0                  # odom 断了超过这么久就当静止


def _odom_cb(msg):
    try:
        tw = msg.twist.twist
        _MOTION['v'] = abs(float(tw.linear.x))
        _MOTION['w'] = abs(float(tw.angular.z))
        _MOTION['ts'] = time.time()
    except Exception:                                     # noqa: BLE001
        pass


def motion_state():
    """返回 (是否在动, 等效速度 m/s)。"""
    now = time.time()
    if _MOTION['ts'] <= 0 or (now - _MOTION['ts']) > _ODOM_TTL:
        return False, 0.0
    v = max(_MOTION['v'], _MOTION['w'] * 0.3)
    return (v > MOVE_V or _MOTION['w'] > MOVE_W), round(v, 3)


def current_mode():
    """当前模式。以**实际在跑的栈**为准：relay_ctl 重启过、或者导航是
    车端直接用命令行起的，MODE 会掉回 idle，但 /amcl 还在跑。"""
    if _NAV_UP:
        return 'navigation'
    return MODE['name']


def _volt_cb(msg):
    try:
        _VOLT['v'] = round(float(msg.data), 3)
        _VOLT['ts'] = time.time()
    except Exception:                                     # noqa: BLE001
        pass


class _VoltHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.path.startswith('/voltage'):
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        now = time.time()
        mv, sp = motion_state()
        body = json.dumps({
            'voltage': _VOLT['v'],
            'age': (round(now - _VOLT['ts'], 1) if _VOLT['ts'] else None),
            'base': _BASE_ALIVE,
            'moving': mv,
            'speed': sp,
            'mode': current_mode(),
        }).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def start_volt_http():
    try:
        srv = ThreadingHTTPServer(('0.0.0.0', VOLT_PORT), _VoltHandler)
    except Exception as e:                                # noqa: BLE001
        rospy.logwarn('relay_ctl: 电量 HTTP 端点没起来 (%s)' % e)
        return
    threading.Thread(target=srv.serve_forever, name='volt-http',
                     daemon=True).start()
    rospy.loginfo('relay_ctl: 电量端点 http://0.0.0.0:%d/voltage' % VOLT_PORT)



def base_node_alive():
    """底盘节点在不在（单底盘 launch、建图或导航 launch 带起来的都算）。"""
    try:
        return bool(rosnode.rosnode_ping('/wheeltec_robot', max_count=1,
                                        verbose=False))
    except Exception:                                     # noqa: BLE001
        return False


def keep_base_alive(_evt=None):
    """定时检查：底盘节点不在就补起一个单底盘 launch（不再抢串口）。"""
    global _LAST_BASE_TRY, _BASE_ALIVE
    now = time.time()
    alive = base_node_alive()
    _BASE_ALIVE = alive
    if now < _BASE_SUPPRESS_UNTIL:
        return
    if alive:
        return
    if now - _LAST_BASE_TRY < 25.0:          # 别把 launch 打架
        return
    _LAST_BASE_TRY = now
    if not ensure_master():
        return
    rospy.loginfo('relay_ctl: 底盘节点不在，补起单底盘 launch（提供 /PowerVoltage）')
    launch('roslaunch turn_on_wheeltec_robot turn_on_wheeltec_robot.launch',
           'relay_base.log')


def kill_launches():
    global _BASE_SUPPRESS_UNTIL
    # 切换 launch 期间别让底盘保活去抢底盘串口（mapping/navigation 自带的底盘节点
    # 起得比较慢，实测要 10~20s）
    _BASE_SUPPRESS_UNTIL = time.time() + 60.0
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


def list_maps(limit=10):
    """扫 ~/maps 下的 *.yaml，按文件 mtime 新的在前。

    2026-10-30：页面上的「最近保存地图」原来只取 last_pose.json 的 time，
    那是**最后一次经 /relay/save_map 保存**的时间。如果地图是 RViz / 命令行
    map_saver 存的，或者状态文件被覆盖过，页面上显示的就**不是最新那张图**。
    直接看文件系统才不会错。mtime 用的是车端时钟，页面会拿它和浏览器时钟
    对比，偏差大时直接提示“车端时钟不可信”。
    """
    out = []
    try:
        names = os.listdir(MAP_DIR)
    except OSError:
        return out
    for n in names:
        if not n.endswith('.yaml'):
            continue
        p = os.path.join(MAP_DIR, n)
        try:
            st = os.stat(p)
        except OSError:
            continue
        out.append({'name': n, 'base': p[:-5], 'mtime': st.st_mtime})
    out.sort(key=lambda d: d['mtime'], reverse=True)
    return out[:limit]


# ---------------- services ----------------

def srv_start_mapping(_req):
    if not ensure_master():
        return TriggerResponse(False, 'ROS master 起不来')
    kill_launches()
    reset_latched_map()          # 先把上一轮 latch 的图冲掉，否则页面看着像没重启
    launch('roslaunch turn_on_wheeltec_robot mapping.launch mapping_mode:=gmapping',
           'relay_mapping.log')
    MODE['name'] = 'mapping'
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
    MODE['name'] = 'navigation'
    return TriggerResponse(True, '正在启动导航（地图 %s），到位后用「设为当前位置」定初始位姿'
                           % os.path.basename(yaml_path))


def srv_stop(_req):
    kill_launches()
    MODE['name'] = 'idle'
    return TriggerResponse(True, '已停止 launch')


def nav_stack_up():
    """导航栈在跑吗？—— master 里有 /amcl 节点就算（只有 navigation.launch 会起它）。

    2026-10-30：页面原来用“点没点过「进入导航」”来判断导航模式，
    但导航完全可能是车端直接起的（用的就是上次保存的图），刷新一下页面
    就“不在导航模式”了，放目标 / 跑巡检都被拦。这个标志让页面能问到真相。
    """
    try:
        # 注意：getSystemState() 返回的是 (话题, 节点列表) 的列表，不是节点名。
        # 想按节点名判断只能用 lookupNode —— 不存在时会抛 MasterError。
        rosgraph.Master('/relay_ctl').lookupNode('/amcl')
        return True
    except Exception:  # noqa: BLE001
        return False


def refresh_mode(_evt=None):
    """定时缓存导航栈状态，供 /voltage 端点（HTTP 线程）读取。

    不要在 HTTP 线程里直接 lookupNode —— 那是走 master XMLRPC，
    每 2 秒一次的轮询没必要花这个钱，而且 master 卡住会拖住请求。
    """
    global _NAV_UP
    try:
        _NAV_UP = nav_stack_up()
    except Exception:                                     # noqa: BLE001
        _NAV_UP = False


def srv_last_pose(_req):
    """返回建图结束时记录的位姿 + 地图清单 + 导航栈状态（JSON 放 message 里）。

    maps[0] = ~/maps 里 mtime 最新的整张图（页面显示「最近保存地图」用）；
    map_base = 导航将要加载的那张（最后一次 save_map 记录的那个）；
    now = 车端当前 unix 时间（页面用它算时钟偏差）；
    nav = 导航栈在跑（/amcl 节点存在）。
  """
    st = read_state()
    st['maps'] = list_maps()
    st['now'] = time.time()
    st['nav'] = nav_stack_up()
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
    # 底盘保活：空闲时也保证 /PowerVoltage 有数据（网页顶栏电量）
    rospy.Timer(rospy.Duration(10.0), keep_base_alive)
    rospy.Timer(rospy.Duration(3.0), keep_base_alive, oneshot=True)
    # 电量/运动状态直接以 HTTP 暴露给板子（不依赖 rosbridge）
    rospy.Subscriber('/PowerVoltage', Float32, _volt_cb, queue_size=1)
    rospy.Subscriber('/odom', Odometry, _odom_cb, queue_size=1)
    start_volt_http()
    # 导航栈状态每 5 秒刷一次（HTTP 线程只读缓存值）
    rospy.Timer(rospy.Duration(5.0), refresh_mode)
    rospy.Timer(rospy.Duration(1.0), refresh_mode, oneshot=True)
    rospy.spin()


if __name__ == '__main__':
    main()
