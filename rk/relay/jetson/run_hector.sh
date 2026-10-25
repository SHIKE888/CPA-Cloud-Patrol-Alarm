#!/bin/bash
# 临时测试用：以 hector 算法起建图（不经过 relay_ctl，方便对比）
#
# roslaunch 必须在 source 过工作空间的 shell 里跑，否则报
# RLException: [mapping.launch] is neither a launch file in package
set -u
source /opt/ros/noetic/setup.bash
source "$HOME/wheeltec_lidar/devel/setup.bash" 2>/dev/null
source "$HOME/wheeltec_robot/devel/setup.bash" 2>/dev/null
cd "$HOME/ros_relay" || exit 1
exec roslaunch turn_on_wheeltec_robot mapping.launch mapping_mode:=hector
