#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修掉车端「断 WiFi 就会废」的两个隐患（只改文件，不影响正在跑的进程）。

1) ~/.bashrc 里 ROS_MASTER_URI 写死 192.168.0.100（wlan0）。WiFi 一关，
   交互 shell 里的 rostopic / rosrun 就连不上 master 了 -> 改成 127.0.0.1。
   同文件的 ROS_HOSTNAME=192.168.0.100 也注释掉，交给 ros_ip_env.sh 自动选。

2) ~/ros_relay/ros_ip_env.sh 的候选网卡列表里没有 eth1（RTL8153 中继链路），
   结果它退到 eth0(192.168.1.102)。把 eth1 提到 eth0 前面，
   以后 ROS_IP 优先用 192.168.100.87 这条千兆链路。

环境变量是进程启动时的快照，改这两个文件只影响下次 start_all.sh 拉起的进程。
"""
import io
import os
import os.path
import shutil

HOME = os.path.expanduser('~')
BRC = os.path.join(HOME, '.bashrc')
RIE = os.path.join(HOME, 'ros_relay', 'ros_ip_env.sh')


def backup(path):
    b = path + '.bak_relay'
    if not os.path.exists(b):
        shutil.copy2(path, b)
        print('备份 -> %s' % b)


# ---------- 1. .bashrc ----------
if os.path.exists(BRC):
    s = io.open(BRC, encoding='utf-8').read()
    orig = s
    s = s.replace(
        'export ROS_MASTER_URI=http://192.168.0.100:11311',
        'export ROS_MASTER_URI=http://127.0.0.1:11311')
    s = s.replace(
        'export ROS_HOSTNAME=192.168.0.100',
        '# ROS_HOSTNAME 交给 ~/ros_relay/ros_ip_env.sh 自动选（eth1 优先）\n'
        '# export ROS_HOSTNAME=192.168.0.100')
    if s != orig:
        backup(BRC)
        io.open(BRC, 'w', encoding='utf-8').write(s)
        print('.bashrc 已修改')
    else:
        print('.bashrc 无需修改')
else:
    print('.bashrc 不存在，跳过')

# ---------- 2. ros_ip_env.sh ----------
if os.path.exists(RIE):
    s = io.open(RIE, encoding='utf-8').read()
    orig = s
    s = s.replace(
        'for _d in enx usbeth0 eth0 wlan0; do',
        'for _d in enx usbeth0 eth1 eth0 wlan0; do')
    if s != orig:
        backup(RIE)
        io.open(RIE, 'w', encoding='utf-8').write(s)
        print('ros_ip_env.sh 已修改（eth1 提到 eth0 前）')
    else:
        print('ros_ip_env.sh 无需修改')
else:
    print('ros_ip_env.sh 不存在，跳过')

# ---------- 结果自检 ----------
print('--- 自检 ---')
for f in (BRC, RIE):
    if os.path.exists(f):
        for i, line in enumerate(io.open(f, encoding='utf-8'), 1):
            if 'ROS_MASTER_URI' in line or 'ROS_HOSTNAME' in line or 'for _d in' in line:
                print('%s:%d: %s' % (os.path.basename(f), i, line.rstrip()))
