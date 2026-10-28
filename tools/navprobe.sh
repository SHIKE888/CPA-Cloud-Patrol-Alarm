set -u
K=/root
echo "== 保存的位姿 state =="
cat $K/.relay_state/last_pose.json 2>/dev/null || cat $K/relay_state/last_pose.json 2>/dev/null || find $K -maxdepth 3 -name 'last_pose.json' 2>/dev/null | head -3
echo
echo "== 地图 yaml 头 =="
ls -t $K/maps/*.yaml 2>/dev/null | head -3
Y=$(ls -t $K/maps/*.yaml 2>/dev/null | head -1)
[ -n "${Y:-}" ] && head -8 "$Y"
echo
echo "== 正在跑的 launch =="
ps -ef | grep -E 'roslaunch|amcl|move_base|gmapping|map_server' | grep -v grep | sed -e 's/  */ /g' | cut -c1-160 | head -12
echo
echo "== ROS 环境 =="
ls -d /opt/ros/* 2>/dev/null
echo
echo "== 当前 /relay/robot_pose =="
source /opt/ros/*/setup.bash 2>/dev/null
source /root/catkin_ws/devel/setup.bash 2>/dev/null || true
timeout 6 rostopic echo -n1 /relay/robot_pose 2>&1 | head -12
echo
echo "== TF map->base_footprint =="
timeout 6 rosrun tf tf_echo map base_footprint 2>&1 | tail -12
