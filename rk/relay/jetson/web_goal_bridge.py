#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""web_goal_bridge —— 网页统一发 /goal_pose，车端转成 move_base action（ROS1）

Foxglove/自研网页无法直接构造 ROS1 action，故在车端做一层 20 行桥接，
让前端逻辑在 ROS1(noetic) 与 ROS2(Nav2) 上保持一致。

用法：
    source /opt/ros/noetic/setup.bash
    ./web_goal_bridge.py            # 默认监听 /goal_pose
    ./web_goal_bridge.py --cancel   # 额外订阅 /web_cancel 用来取消当前目标
"""
import argparse
import rospy
import actionlib
from geometry_msgs.msg import PoseStamped
from move_base_msgs.msg import MoveBaseAction, MoveBaseGoal


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--goal-topic', default='/goal_pose')
    ap.add_argument('--cancel-topic', default='/web_cancel')
    ap.add_argument('--cancel', action='store_true', help='订阅取消话题')
    ap.add_argument('--frame', default='', help='强制改写 frame_id（默认沿用消息里的）')
    args = ap.parse_args()

    rospy.init_node('web_goal_bridge')
    client = actionlib.SimpleActionClient('move_base', MoveBaseAction)
    rospy.loginfo('waiting for move_base action server ...')
    if not client.wait_for_server(rospy.Duration(30.0)):
        rospy.logerr('move_base action server 不在，桥接退出（导航栈是否已启动？）')
        return

    def goal_cb(msg):
        goal = MoveBaseGoal()
        goal.target_pose = msg
        if args.frame:
            goal.target_pose.header.frame_id = args.frame
        if not goal.target_pose.header.frame_id:
            goal.target_pose.header.frame_id = 'map'
        client.send_goal(goal)
        rospy.loginfo('goal -> move_base: (%.2f, %.2f)',
                      msg.pose.position.x, msg.pose.position.y)

    def cancel_cb(_msg):
        rospy.logwarn('cancel current goal')
        client.cancel_all_goals()

    rospy.Subscriber(args.goal_topic, PoseStamped, goal_cb, queue_size=1)
    if args.cancel:
        rospy.Subscriber(args.cancel_topic, PoseStamped, cancel_cb, queue_size=1)
    rospy.loginfo('web_goal_bridge ready: %s -> move_base', args.goal_topic)
    rospy.spin()


if __name__ == '__main__':
    main()
