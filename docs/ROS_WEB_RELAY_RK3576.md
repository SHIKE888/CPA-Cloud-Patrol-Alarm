# ROS 智能车 Web 化建图/导航 —— 以 RK3576 为中继的方案（V2.1）

> 基于原方案 `ROS智能车Web化建图与导航中继方案.pdf`（V1.0，中继=香橙派 Zero 3 / NanoPi R2S）
> **改写为以本工程 RK3576 板为中继**，并按"网卡未到货"的现实拆出阶段 0 前置预备。
> 编制日期：2026-10-21 · 全部环境数据为板上实测
>
> **V2.1 变更（2026-10-21 晚）**：车端「一次 sudo 密码」全部去掉 —— 改为**纯用户态方案**；
> 车端 IP 改由中继 DHCP 下发（车端零配置）；`foxglove_bridge` 用离线 deb 解包到用户目录，已实测启动；
> 补充 NAT 三条路线与内核实测依据（§8.4）。

---

## 1. 结论（一页版）

| 结论 | 内容 |
|---|---|
| 中继硬件 | **RK3576（MLK-AFC03 板）**，8 核、1.9 GB RAM、双千兆 `end0/end1` + WiFi，性能远超原方案的 4×A53 |
| 中继软件 | **不装 ROS**（Debian 12 无 Noetic 源）。只做 `nginx` 反代 + 静态页 + `dnsmasq`(DHCP) + `chrony` + `avahi`，CPU 占用可忽略 |
| 桥接位置 | **`foxglove_bridge` 跑在车端**（Jetson，Noetic 有原生包），WebSocket 经中继 nginx 转发到浏览器 |
| 车端链路 | Jetson 板载 `eth0` 已被占用 → 用 **RTL8153 USB 千兆网卡**（驱动内核已内建 r8152 v1.11.11，免装） |
| 中继内网口 | **`end1` 空闲千兆口直连车端**（`end0` 继续给 PC ICS 调试用，不动） |
| 网段 | 车端↔中继 `192.168.100.0/24`；外部 WiFi 沿用 `509`（`192.168.1.0/24`） |
| 中继能否给车端 NAT 出网 | 默认**不做 NAT**；车端需要出网时走中继的**用户态 HTTP 代理**（apt/pip/git 够用）。真要三层 NAT 可补编内核模块，见 §8.4 |
| 车端是否要 sudo | **不要**。全部用户态：deb 解包到 `~/ros_ext`、`crontab @reboot` 自启、IP 由中继 DHCP 下发 |
| 当前状态 | 见 §6 的"已完成"清单：中继 5 项服务已验收；车端 `foxglove_bridge` 8765 实测起得来；USB 网卡到货后按 §9 联调 |

---

## 2. 与 PDF 原方案的差异（为什么要改）

| # | 原方案 | 本方案 | 原因 |
|---|---|---|---|
| 1 | 中继上跑 `foxglove_bridge`（中继以 ROS 节点身份订阅） | **bridge 跑车端，中继只做 WS 反代** | RK 板是 **Debian 12**，ROS Noetic 官方 apt 只到 Ubuntu 20.04(focal)。在 Debian 12 装 Noetic 只能走 RoboStack/Conda，代价大、占内存，而中继本机已在跑 MIPI 推流+云平台。bridge 在车端功能等价：车端序列化 → WebSocket → 中继 TCP 转发 → 浏览器 |
| 2 | 中继用「四核 A53 + 1 GB」 | **RK3576 8 核 + 1.9 GB，且自带双千兆** | 中继侧**不用再买网卡**：`end1` 空闲，直接当车端口 |
| 3 | 车端另一个网口 | 相同：Jetson `eth0` 已占，必须加 **RTL8153** | 与 PDF 一致，已实测驱动内建 |
| 4 | 车端装包要联网 | **离线 deb + `dpkg -x` 解包到用户目录**（已做） | 车上无外网、不给 sudo 密码；`foxglove_bridge` 0.8.4 + `ros_babel_fish` 0.9.3 已解包并实测可启动 |
| 5 | 车端静态 IP | **中继 `dnsmasq` 发 DHCP**，车端 USB 网卡插上自动拿 `192.168.100.x` | 车端 NM 对有線口默认就是 `auto`，不需要任何 root 操作 |

代价：中继不能自己当 ROS 节点（无法在中继侧做 rosbag 录制、多车聚合）。若后续需要，再按 §11 的"二期"用 RoboStack 补。

---

## 3. 实测环境（2026-10-21）

### 3.1 中继：RK3576（`ssh afc03`）

| 项 | 值 |
|---|---|
| OS / 内核 | Debian GNU/Linux 12 (bookworm) / `6.1.99` |
| CPU / 内存 | 8 核 / 1.9 GB（部署后可用约 1.2 GB） |
| 磁盘 | `/dev/root` 14 G，已用 40% |
| 网口 | `end0` = 192.168.137.100（PC ICS，调试用）；`end1` = 空闲（本次用作车端口）；`wlx8c7ab3f8171b` = 192.168.1.136（WiFi 509，默认路由） |
| 已装（本次新装） | nginx 1.22.1、chrony 4.3、avahi-daemon 0.8；dnsmasq 已装（配置待部署，见 §6.1 #9） |
| 内核 netfilter | 实测 `/proc/config.gz`：`CONFIG_NETFILTER=y`、`CONFIG_IP_NF_IPTABLES=y`，但 **`CONFIG_NF_TABLES` 未启用**、**`CONFIG_NF_CONNTRACK` 未启用** → `iptables-legacy -t nat` 报 `Table does not exist` |
| 内核模块能力 | `CONFIG_MODULES=y`、**`MODVERSIONS` 关**、**`MODULE_SIG` 关**、`modules_disabled=0`、`vermagic=6.1.99 SMP mod_unload aarch64` → **自己编的 `.ko` 可直接 insmod**（§8.4 B 路线可行） |
| 已有负载 | MIPI 推流 9012、cloud-agent（与本方案互不干扰） |

### 3.2 车端：Jetson Orin Nano（`ssh ros` = wheeltec@192.168.0.100）

| 项 | 值 |
|---|---|
| OS / 内核 | Ubuntu 20.04.5 LTS / `5.10.104-tegra` aarch64 |
| ROS | Noetic（`/opt/ros/noetic`），源已配 `mirrors.tuna.tsinghua.edu.cn/ros/ubuntu focal` |
| 已有包 | `move_base`、`amcl`、`gmapping`、`map_server`、`teb_local_planner`、`cartographer_ws`(已编译)、`wheeltec_lidar`、`wheeltec_robot` |
| 缺 | `rosbridge_server`、`slam_toolbox`（`foxglove_bridge` 已用离线 deb 解包到 `~/ros_ext`，**实测可启动**） |
| 网络 | `eth0` 192.168.1.102（对端只 ARP 到 `192.168.1.200`，网关 .1 不通）；`wlan0` **AP 模式 192.168.0.100**；`docker0` |
| 外网 | **无**（DNS 解析失败、`ping 8.8.8.8` 100% loss） |
| USB 网卡 | 未插（`lsusb` 无 Realtek），驱动 `r8152` = builtin v1.11.11，固件 `rtl8153a/b/c` 齐全 |
| 时间 | 与 PC 相差约 8 小时（板上时间戳为 2024-06-26）。**本方案不需要双端对时**（中继不跑 ROS，时间戳只在车端内部闭环）；若以后中继也要当 ROS 节点再启用 chrony 客户端 |

### 3.3 已发现的三个隐患（务必在联调前处理）

1. **网段冲突**：车端 `eth0` 现在是 `192.168.1.102/24`，与外部 WiFi 509 的 `192.168.1.0/24` **重叠**。
   实测该口只 ARP 到 `192.168.1.200`，网关 `.1` 不通 —— 说明它接的是车上另一个 `192.168.1.x` 小网（雷达/交换机）。
   → 本方案把**车端↔中继**固定在 `192.168.100.0/24` 规避；但 **车端 eth0 与 WiFi 若同网段**，路由会互相顶掉，需按 §7 处理。
2. **Jetson 无外网** —— 已用离线 deb 解决（§8.1 A 路径），不再依赖 PC。
3. **双端时间不同步** —— 本方案**不需要**对齐（中继不跑 ROS）；车端内部时间戳自洽即可。

---

## 4. 总体架构

```
┌──────────────────────── 车端 Jetson Orin Nano (192.168.100.1) ────────────────────────┐
│  2D 雷达驱动  轮速里程计  slam_toolbox/gmapping   move_base + amcl                   │
│                                                                                      │
│  foxglove_bridge :8765  ← 订阅 /map /scan /tf /plan /amcl_pose                        │
│  rosbridge_server :9090 ← 备选（自研页面用）                                          │
│  web_goal_bridge.py     ← /goal_pose → move_base action（ROS1 兼容层）                 │
│                                                                                      │
│  eth0        : 车上雷达/设备小网（192.168.1.x，风险：与 WiFi 同段）                     │
│  enx*/usbeth0: RTL8153 → DHCP（中继发放 192.168.100.50~150，零配置）                   │
└──────────────────────────────┬───────────────────────────────────────────────────────┘
                               │ 超五类网线直连（二层，亚毫秒）
┌──────────────────────────────┴──────────── RK3576 中继 (192.168.100.2) ───────────────┐
│  end1  : 192.168.100.2/24（静态，never-default）                                       │
│  wlx…  : 192.168.1.136（STA 接外部 WiFi 509，默认路由）                                │
│                                                                                      │
│  nginx :80        /            → /var/www/ros-relay（静态页，离线可用）                │
│                   /foxglove    → proxy_pass 192.168.100.1:8765（WebSocket）            │
│                   /rosbridge   → proxy_pass 192.168.100.1:9090（WebSocket）            │
│                   /relay-health→ 中继自检 JSON                                        │
│  dnsmasq         → end1 发 DHCP（车端插上就有地址，零配置）                              │
│  chrony          → 作为 192.168.100.0/24 的 NTP 源（可选）                             │
│  avahi-daemon    → 局域网 mDNS 广播                                                   │
│  （无 ROS、无 Docker、无视频编码）                                                     │
└──────────────────────────────┬───────────────────────────────────────────────────────┘
                               │ 外部 WiFi（509）
┌──────────────────────────────┴───────────────────────────────────────────────────────┐
│ 浏览器（手机/平板/PC）：http://<中继IP>/  →  Foxglove Studio 或自研页面                │
│  上行订阅：/map /scan /tf /plan /amcl_pose    下行发布：/initialpose /goal_pose /cmd_vel│
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**数据流方向不变**，但每个环节的落点变了：

| 环节 | 原方案 | 本方案 |
|---|---|---|
| ROS 数据 → WebSocket | 中继上跑的 bridge | **车端** bridge |
| WebSocket → 浏览器 | 中继直出 8765 | 中继 nginx 80 → 反代 8765 |
| 浏览器访问地址 | `ws://中继:8765` | `ws://中继/foxglove`（单端口 80，防火墙更简单） |

---

## 5. 网络规划

| 设备 / 接口 | 地址 | 说明 |
|---|---|---|
| 车端 USB 网卡（RTL8153） | **DHCP**（中继 dnsmasq 发 `192.168.100.50~150`） | 车端零配置：NM 对有线口默认 `auto`，插上即拿地址；中继故意不下发 router 选项 |
| 中继 `end1` | `192.168.100.2/24` | 静态，`ipv4.never-default yes`（实测已配置） |
| 中继 `wlx8c7ab3f8171b` | DHCP `192.168.1.136/24` | 默认路由，出网与局域网服务 |
| 中继 `end0` | `192.168.137.100/24` | 保持现状（PC ICS），与中继功能无关 |
| 客户端浏览器 | 同一 WiFi 509 | `http://192.168.1.136/` |
| 车端 `eth0` | 车上雷达网段 | **建议改成非 192.168.1.x**（见 §7） |

端口表：

| 端口 | 在哪 | 用途 | 是否对局域网开放 |
|---|---|---|---|
| 80 | 中继 | 网页 + WS 反代 + 自检 | ✅ |
| 8765 | 车端 | foxglove_bridge | ❌ 只被中继反代 |
| 9090 | 车端 | rosbridge_server | ❌ 只被中继反代 |
| 11311 | 车端 | ROS master | ❌ 仅本机/车端局域网 |
| 9012 | 中继 | MIPI 推流（既有） | ✅ 与本方案无关 |

---

## 6. 阶段 0：网卡到货前已完成的前置工作（✅ = 本次已做并验收）

### 6.1 中继端（RK3576）— 8 项已完成，DHCP 待部署

| # | 项 | 状态 | 证据 |
|---|---|---|---|
| 1 | `end1` 静态地址预留 | ✅ | `nmcli -g ipv4.method,ipv4.addresses,ipv4.never-default con show ros-relay-eth` → `manual / 192.168.100.2/24 / yes` |
| 2 | `ip_forward=1`（持久化 `/etc/sysctl.d/90-ros-relay.conf`） | ✅ | `cat /proc/sys/net/ipv4/ip_forward` → `1` |
| 3 | nginx 站点（静态页 + `/foxglove`、`/rosbridge` WS 反代） | ✅ | `nginx -t` 通过；`http://192.168.1.136/` → 200 |
| 4 | 中继自检接口 | ✅ | `curl http://192.168.1.136/relay-health` → `{"role":"rk3576-relay",...}` |
| 5 | chrony 作为车端 NTP 源 | ✅ | `chrony active`，配置 `allow 192.168.100.0/24` + `local stratum 8` |
| 6 | avahi mDNS | ✅ | `avahi-daemon active` |
| 7 | NAT | ⚠️ 默认不启用 | 内核 `NF_TABLES`/`NF_CONNTRACK` 都未编译；已 `systemctl mask nftables` 避免开机报错。可选方案见 §8.4 |
| 8 | 一键部署脚本（幂等） | ✅ | `rk/relay/deploy_relay.sh`（板上 `/root/rk/relay/`） |
| 9 | DHCP（车端零配置的关键） | ⏳ 配置已写、**待部署** | `rk/relay/dnsmasq-ros-relay.conf`（`interface=end1`、range `192.168.100.50-150`、不下发 router） |

> 注：`end1` 现在 `DOWN`（无网线，`NO-CARRIER`）是**正常状态**；插上 RTL8153 后 NM 会自动激活该 profile。

### 6.2 车端（Jetson）— 已完成，**全程未用 sudo**

| # | 项 | 状态 | 证据 / 位置 |
|---|---|---|---|
| 1 | `foxglove_bridge` 离线安装 | ✅ | `tools/debs/ros-noetic-foxglove-bridge_0.8.4_arm64.deb` → `dpkg -x` 到 `~/ros_ext` |
| 2 | 依赖 `ros_babel_fish` 补齐 | ✅ | `ros-noetic-ros-babel-fish_0.9.3_arm64.deb`（之前报 `libros_babel_fish.so` 找不到） |
| 3 | 启动脚本 | ✅ | `~/ros_relay/start_bridge.sh`（bash，**必须带 `CMAKE_PREFIX_PATH`**，否则 nodelet 插件找不到） |
| 4 | 实际启动验证 | ✅ | `ss -lnt` → `0.0.0.0:8765 LISTEN`；PC `curl http://192.168.0.100:8765/` → **426 Upgrade Required**（bridge 存活、拒绝非 WS 请求） |
| 5 | 开机自启 | ✅ | 用户 crontab：`@reboot sleep 25 && $HOME/ros_relay/start_bridge.sh` |
| 6 | `ROS_IP` 自动选择 | ✅ | `~/ros_relay/ros_ip_env.sh` 已挂进 `~/.bashrc`（优先级 `enx* > usbeth0 > eth0 > wlan0`） |
| 7 | 网页目标点桥接 | ✅ | `~/ros_relay/web_goal_bridge.py`（`/goal_pose` → `move_base` action） |
| 8 | 静态 IP / udev 固定名 / chrony | ❌ **不做** | 改由中继 DHCP 下发；`apply_prep.sh`（需 sudo）降为可选脚本，本方案不用 |
| 9 | `rosbridge_server` 离线安装 | ✅ | 4 个 deb（rosbridge-server/library/msgs/rosapi）+ `rosauth` + tornado wheel + pymongo(bson) wheel，`dpkg -x`/解压到 `~/ros_ext`；**`ws://0.0.0.0:9090` 实测已监听** |
| 10 | 自研地图网页（不需 Foxglove 账号） | ✅ | `rk/relay/web/map.html` + `vendor/roslib.min.js`，部署在 `http://<中继>/map.html`；**地图渲染与点击下发均实测通过** |

> 踩过的坑（已验证）：
> - 脚本用 `#!bin/sh` 时 `. /opt/ros/noetic/setup.bash` 会卡住/失败 → 改 **bash**；
> - source `wheeltec_*` 的 `devel/setup.bash` 很慢（>6 s），bridge 不需要 → 默认不 source（`ROSOURCES_WS=1` 才加）；
> - 缺 `CMAKE_PREFIX_PATH=~/ros_ext/opt/ros/noetic` 时，pluginlib 找不到 nodelet 插件库。

### 6.3 PC 端（仅开发期用，现场不需要）

| # | 项 | 状态 |
|---|---|---|
| 1 | 车端临时出网跳板（HTTP/HTTPS 代理 + SSH 反向隧道） | ✅ `tools/pc_http_proxy.py`，实测车端 `curl -x http://127.0.0.1:8811` 下载 tuna 的 `Release` 成功（3797 B） |
| 2 | `~/.ssh/config` 别名 `ros` / `ros-root`，免密登录 | ✅ |
| 3 | 下载 arm64 focal deb（离线包） | ✅ `tools/debs/` 两个包 |

---

## 7. 车端 eth0 网段冲突的处理

现状：车端 `eth0 = 192.168.1.102/24`，而外部 WiFi 509 也是 `192.168.1.0/24`。
**后果**：两网段相同 → 车端会认为"WiFi 网段是直连的"，导致去往 509 其他设备（PC 192.168.1.117、中继 192.168.1.136）的包从 `eth0` 发出去 → 不通。

处理顺序（不着急，网卡到货前做也行）：

1. **首选**：确认车上 `eth0` 接的到底是什么（雷达？交换机？）。若是雷达且支持改 IP，把雷达改成 `192.168.10.x`，`eth0` 跟着改，彻底避开。
2. **次选**：把外部 WiFi 换成 `192.168.50.0/24`（路由器改 LAN 网段），车端 WiFi 不用时可直接关掉。
3. **临时**：车端不接 WiFi（`wlan0` 当 AP 即可），`192.168.1.x` 只留给车上小网，浏览器走中继的 509 —— 此时车端根本不需要外网，冲突自然消失。

> 现状下 `wlan0` 是 AP 模式（192.168.0.0/24），与 `192.168.1.0/24` 不冲突，所以浏览器侧暂时没问题。

---

## 8. 阶段 1：车端实施（已改为**纯用户态**，不需要 sudo）

> V2.0 写的"需要一次 sudo 密码"已作废：实测终端里 sudo 密码**不回显**，现场也没地方输。
> 现全部改走用户态：deb 解包 + `crontab @reboot` + 中继 DHCP。

### 8.1 车端装包的三种路径（按现场条件选）

| 路径 | 适用 | 代价 |
|---|---|---|
| **A. 离线 deb 解包**（✅ 已用） | 无外网、无 sudo | 不装进系统，包在 `~/ros_ext`；依赖要自己补齐 |
| B. 中继用户态 HTTP 代理 | 需要经常装新包 | 车端要设 `http_proxy=http://192.168.100.2:8888`（不改内核） |
| C. 补编内核开 NAT | 需要车端像正常主机一样上网（任意协议） | 编模块 + insmod，见 §8.4 |

**A 路径实际做了什么**（PC 下载 → `scp` → 车上 `dpkg -x`，全程无 root）：

```bash
# PC（开发期）
curl -O http://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu/pool/main/r/ros-noetic-foxglove-bridge/ros-noetic-foxglove-bridge_0.8.4-1focal.20250520.090425_arm64.deb
curl -O http://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu/pool/main/r/ros-noetic-ros-babel-fish/ros-noetic-ros-babel-fish_0.9.3-1focal.20250520.085837_arm64.deb
scp *.deb ros:~/ros_relay_prep/

# 车端（用户态）
mkdir -p ~/ros_ext
dpkg -x ~/ros_relay_prep/ros-noetic-foxglove-bridge_0.8.4_arm64.deb ~/ros_ext
dpkg -x ~/ros_relay_prep/ros-noetic-ros-babel-fish_0.9.3_arm64.deb ~/ros_ext
```

### 8.2 车端启动（已验证可用）

```bash
# 启动（脚本内部自动设 ROS_PACKAGE_PATH / LD_LIBRARY_PATH / CMAKE_PREFIX_PATH / ROS_IP）
~/ros_relay/start_bridge.sh &
# 验收
ss -lnt | grep 8765        # 期望 0.0.0.0:8765 LISTEN
```

开机自启已写入用户 crontab：`@reboot sleep 25 && $HOME/ros_relay/start_bridge.sh`
（注意：cron 里 `$HOME` 会展开；换用户/改路径要同时改这一行）

### 8.3 可选：需要 sudo 的"正统安装"（本方案不用）

`~/ros_relay_prep/apply_prep.sh` 保留着，只在“拿到 sudo 且有外网”时用：
`ssh -t ros 'sudo sh ~/ros_relay_prep/apply_prep.sh --with-ros'`（会装 udev 固定名、静态 IP、chrony、apt 包）。
**本方案不需要它**，因为 IP 由中继 DHCP 下发、时间不需要对齐、包已离线解包。

### 8.4 起步顺序（每次上车）

```bash
# ① 车端：bridge（已由 crontab 自启；需要手动重启就用这条）
~/ros_relay/start_bridge.sh &

# ② 车端：建图 / 导航（WHEELTEC 包，mapping_mode 可选 gmapping/hector/cartographer/karto，默认 karto）
source /opt/ros/noetic/setup.bash
source ~/wheeltec_lidar/devel/setup.bash
source ~/wheeltec_robot/devel/setup.bash
roslaunch turn_on_wheeltec_robot mapping.launch mapping_mode:=gmapping
# 建图完成后： roslaunch turn_on_wheeltec_robot navigation.launch

# ③ 车端：网页下发目标点（可选）
python3 ~/ros_relay/web_goal_bridge.py &

# ④ 中继：无需操作（systemd 固化）
ssh afc03 'systemctl is-active nginx chrony avahi-daemon dnsmasq'

# ⑤ 浏览器：打开 http://<中继IP>/  →  Foxglove Studio 连 ws://<中继IP>/foxglove
```

---

### 8.5 让车端能出网（NAT）的三条路线

> 前提实测（`/proc/config.gz`）：`CONFIG_NF_TABLES` **未启用**、`CONFIG_NF_CONNTRACK` **未启用**、
> `iptables-legacy -t nat` → `Table does not exist`；
> 但 `CONFIG_MODULES=y`、`MODVERSIONS` 关、`MODULE_SIG` 关、`modules_disabled=0`、`vermagic=6.1.99 SMP mod_unload aarch64`。

| 路线 | 做法 | 代价 | 能力 |
|---|---|---|---|
| **A. 用户态 HTTP 代理**（推荐先做） | 中继跑 `python3` 代理（标准库，零依赖），车端 `export http_proxy=http://192.168.100.2:8888` | 5 分钟，**不动内核不重启** | `apt` / `pip` / `git` / `curl` 够用；**UDP、ICMP 不行** |
| **B. 补编 netfilter 模块** | VM 里把 `NF_CONNTRACK / NF_NAT / NF_DEFRAG_IPV4 / IP_NF_NAT / IP_NF_TARGET_MASQUERADE` 改 `=m`，只 `make modules`，拷 6~8 个 `.ko` 到板子 `insmod` | 30–40 分钟，**不换 boot.img、不重启** | 完整三层 NAT |
| **C. 重编内核** | defconfig 改 `=y`，`make mlk-afh03-rk3576-linux.img`，刷 boot 分区 | 1 小时 + **重启**（会打断 FPGA/MIPI 链路，需重新验证） | 完整、且开机即生效 |

**B 路线的两个已知坑**：

1. `CONFIG_NETFILTER_ADVANCED` 当前未开，开启后会影响一批 netfilter 选项的可见性 →
   必须 `make olddefconfig` 后 **diff 整个 `.config`**，确认没把别的选项顺手改掉。
2. 板上 `/lib/modules/6.1.99/` 目前只有 `bcmdhd.ko`（没有完整模块树）→ 拷进去后要 `depmod -a`，
   或按依赖顺序手工 `insmod`（`nf_conntrack` → `nf_defrag_ipv4` → `nf_nat` → `iptable_nat` → `ipt_MASQUERADE`）。

**建议**：本方案里浏览器只跟中继通信，**NAT 不是必需**。只有将来要给车端跑 `rosdep`/`pip install torch` 这类大量联网操作时才值得上 B/C。

---

### 8.6 网页端（B 方案：自研页面，已实现并实测）

Foxglove Studio 网页版**强制登录**（Microsoft/SSO/邮箱），现场不一定有账号 → 改为自研单页。

**组成**（全部离线，无外网依赖）：

| 文件 | 作用 |
|---|---|
| `rk/relay/web/map.html` | 地图/激光/位姿渲染 + 点击下发目标点 + 右键设初始位姿 + 滚轮缩放/拖拽 |
| `rk/relay/web/vendor/roslib.min.js` | roslib 1.3.0（唯一前端依赖） |
| `rk/relay/jetson/start_rosbridge.sh` | 车端用户态启动 `rosbridge_websocket :9090` |
| `rk/relay/jetson/fake_map.py` | 发布假 OccupancyGrid，联调时验证渲染链路（不动底盘） |
| `tools/probe_rosbridge.py` | 纯 Python 订阅 `/map`，验证 rosbridge 数据通路 |

**访问**：`http://<中继IP>/map.html`，页面顶部填 WebSocket 地址：

- 网卡到货前：`ws://192.168.0.100:9090`（PC 直连车端 AP）
- 网卡到货后：`ws://<中继IP>/rosbridge`（nginx 反代，单端口 80）

**实测证据（2026-10-21，闭环）**：

```
# ① 后端：rosbridge 能推地图
probe_rosbridge → publish #1: 200x200 @ 0.050 m/px, data_len=40000
                  publish #2: 同上（周期重发）

# ② 前端：页面连接并渲染
状态=已连接  /map=200×200 @ 0.050 m/px  缩放=28.60 px/m

# ③ 闭环：网页点击 → 车端 ROS 真收到
页面   ：/goal_pose ← (4.40, 4.52)
车端   ：/tmp/goal.txt → 0,1,0,map,4.4,4.52,0.0,0.0,0.0,0.0,1.0
         rostopic info /goal_pose → Publishers: /rosbridge_websocket
```

**开机自启（用户 crontab，无需 sudo）**：`rk/relay/jetson/add_autostart.sh`

```
@reboot sleep 25 && $HOME/ros_relay/start_bridge.sh >> $HOME/ros_relay/bridge.log 2>&1
@reboot sleep 30 && $HOME/ros_relay/start_rosbridge.sh 9090 >> $HOME/ros_relay/rosbridge.log 2>&1
```

> 两者都依赖 ROS master(11311)。开机后跑 `roslaunch ...`（如 `mapping.launch`）会自动拉起 master，
> 它们会自己连上；若一直没起 master，日志会持续打印重试。

> 坑：`rosbridge_server` 运行依赖 `rosauth`（缺失）和 `bson`（pymongo 提供）与 `tornado`
> （系统 python3.8 没有），三者均已在 `tools/debs/` 里离线备齐。

#### 8.6.1 建图启动实录（2026-10-21，已跑通）

```bash
ssh ros 'source /opt/ros/noetic/setup.bash
         source ~/wheeltec_lidar/devel/setup.bash
         source ~/wheeltec_robot/devel/setup.bash
         roslaunch turn_on_wheeltec_robot mapping.launch mapping_mode:=gmapping'
```

**踩到的坑：`yesense_imu_node` 串口冲突导致 launch 整体退出**

| 现象 | `REQUIRED process [yesense_imu_node-6] has died` → `Initiating shutdown!` |
|---|---|
| 报错 | `SerialException: device reports readiness to read but returned no data` |
| 根因 1 | `/dev/wheeltec_IMU` 与 `/dev/wheeltec_controller` **都指向 `ttyCH343USB0`** —— udev 里 IMU 那条规则**没写 serial 条件**，谁后触发谁覆盖 |
| 根因 2 | `include/base_serial.launch:5` 的 `use_wheeltec_imu` 默认 `true`，而上层 `turn_on_wheeltec_robot.launch` **没有把这个 arg 传下去** |
| 修复 | `sed -i 5s/true/false/ include/base_serial.launch`（备份 `.bak_rosrelay`），改用控制板板载 IMU |

**修复后实测**：

```
/scan  → average rate: 9.997 Hz（1354 点/帧）
/map   → 192×160 @ 0.050 m/px，origin (-5.0, -4.0)
网页   → 已连接 / /map 192×160 / /scan 1354 点·10.1 Hz / 缩放 45.31 px/m
gmapping → Laser Pose= 0.12 0 -1.57 / Registering First Scan
```

> 注意：`mapping.launch` 只起 gmapping，**没有 move_base**，所以此时网页点目标点
> 虽然能发到 `/goal_pose`，但没人接。要做导航需换 `navigation.launch`（并配好地图/amcl）。

#### 8.6.2 网页控制台（V2 功能，2026-10-21 已实现）

| 功能 | 实现 | 验证 |
|---|---|---|
| 显示机器人位置与朝向 | 车端 `relay_ctl` 以 map 系发 `/relay/robot_pose`（PoseStamped, 10 Hz），页面画箭头+朝向扇形 | ✅ 页面显示 `0.05, 0.05 @ -3°` |
| 四向方向键 | 按住 → 10 Hz 持续发 `/cmd_vel`，松开发 0；线速/角速可在页面调 | ✅ 车端 `/cmd_vel` 收到 `linear.x=0.15` |
| 停车 | 「停」按钮 + 「停止全部」 | ✅ |
| 开始建图 | `/relay/start_mapping`（std_srvs/Trigger）→ 杀旧 launch 起 `mapping.launch` | 服务已注册 |
| 保存建图 | `/relay/save_map` → `map_saver` 到 `~/maps/map_<时间戳>`，同时记录当时位姿 | ✅ 生成 `map_20240626_144039.pgm`(30 KB)+yaml，位姿 `(0.02,-0.08,1.6°)` |
| 进入导航 | `/relay/start_navigation` → 用**保存的最新地图**起 `navigation.launch map_file:=...` | 服务已注册（切换会重启 launch） |
| 设为建图结束位置 | `/relay/last_pose` 返回 JSON，页面解析后发 `/initialpose` | ✅ JSON 返回正常 |
| 手动设初始位姿 | 右键点地图 → `/initialpose` | ✅ |
| 删除导航点 | 发 `/move_base/cancel`（GoalID 全零）并清除绘制 | ✅ |
| 实时路径 | 订阅 `/move_base/NavfnROS/plan`（全局，蓝）与 `/move_base/DWAPlannerROS/local_plan`（局部，橙） | 需导航模式才有数据 |

**车端 `relay_ctl.py` 的服务**（`std_srvs/Trigger`，全部在 `/relay/` 下）：

```
start_mapping      杀 launch + 起 mapping.launch（确保 master 独立存在）
save_map           map_saver + 记录 map->base_footprint 位姿到 ~/ros_relay/last_pose.json
start_navigation   用 last_pose.json 里的地图起 navigation.launch
last_pose          返回 {"map_base":..., "pose":{x,y,yaw}, "time":...}
stop               杀 launch（保留 master）
```

> 坑：**前端 `ROSLIB.TFClient` 在本项目里拿不到位姿**（车端 `tf_echo map base_footprint` 明明有数据）。
> 改为车端节点直接发布 `/relay/robot_pose` 话题，问题消失，且省掉浏览器端的 TF 链式计算。

---

## 9. 阶段 2：网卡到货后的 30 分钟联调

| 步 | 动作 | 验收标准 |
|---|---|---|
| 1 | RTL8153 插车端 **USB 3.0** 口 | `lsusb` 见 `0bda:8153`；`ls /sys/class/net` 多出 `enx*`（DHCP 方案不依赖固定名） |
| 2 | 网线连车端 USB 网卡 ↔ 中继 `end1` | 车端 `ethtool enxXXXX` → `Speed: 1000Mb/s`；中继 `ip -br addr show end1` → `UP` + `192.168.100.2/24` |
| 3 | 车端自动拿地址（**零配置**） | 车端 `ip -4 addr show enxXXXX` 得到 `192.168.100.50~150`；中继 `cat /var/lib/misc/dnsmasq.leases` 能看到这条租约 |
| 4 | 双向 ping | 车端 `ping 192.168.100.2`、中继 `ping <车端拿到的 IP>` 均 <1 ms |
| 5 | bridge 起来 | 车端 `~/ros_relay/start_bridge.sh &` → `ss -lnt \| grep 8765` 有 `0.0.0.0:8765`（已实测）；中继侧 `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/foxglove` → **426**（反代通，bridge 拒绝非 WS 请求） |
| 6 | 浏览器闭环 | 打开 `http://192.168.1.136/` → Foxglove 连 `ws://192.168.1.136/foxglove` → 能看到 `/map`、`/scan`、`/tf` |
| 7 | 网页下发目标点 | Foxglove `Publish` 面板发 `/goal_pose`（`geometry_msgs/PoseStamped`, frame `map`）→ 车动 |
| 8 | 断电重启验证 | 整车断电再上电，中继 `nginx/dnsmasq/avahi` 自启、车端 `crontab @reboot` 拉起 bridge、浏览器免配置可连 |

---

## 10. 带宽 / 算力 / 延迟评估

| 数据流 | 规模 | 带宽 |
|---|---|---|
| `/scan`（360 点 @10 Hz） | ~1.5 KB/帧 | ~15 KB/s |
| `/tf` | 数百 B × 50–100 Hz | 20–50 KB/s |
| `/map`（200 m²） | 0.1–2 MB，latched | 均值 < 100 KB/s |
| `/plan`、`/amcl_pose` | 数 KB | < 20 KB/s |
| `/camera/image_raw/compressed`（可选） | 640×480@15 | ~3.6 Mbps |

- 中继 CPU：仅 nginx TCP 转发（零拷贝级别），实测静态页 + 反代常驻内存 < 20 MB，
  **远低于**原方案在中继做 ROS 序列化的开销。
- 延迟：有线亚毫秒；WS 序列化 + WiFi 约 10–50 ms；主要延迟来自地图消息周期性刷新。
- WiFi 侧：`509` 实测吞吐约 25 Mbps（既有推流占用），ROS 数据 <200 KB/s，余量充足。

---

## 11. 已知限制与后续

| 限制 | 影响 | 解决路径 |
|---|---|---|
| 中继默认无 NAT | 车端不能像正常主机一样出网 | ① 中继用户态 HTTP 代理（推荐）② 补编 netfilter 模块 ③ 重编内核，详见 §8.5 |
| 中继不跑 ROS | 不能在中继侧录 rosbag / 聚合多车 | 二期：Debian 12 上装 RoboStack（conda 版 Noetic），或换 Ubuntu 22.04 + ROS2 Humble 镜像 |
| `slam_toolbox` 未装 | 只能用 `gmapping` / `cartographer`（已有） | 同 §8.1 A 路径：下载 `ros-noetic-slam-toolbox` 的 arm64 deb → `dpkg -x` 到 `~/ros_ext` |
| 双端时间 | 车端 RTC 与 PC 差 8 小时 | **本方案不需要对齐**（中继不跑 ROS）；如以后中继也跑 ROS，再启用 `chrony-client.conf` |
| 网页端 | Foxglove Studio 网页版需外网加载 | 阶段 2 可选：把 Studio 构建产物放到 `/var/www/ros-relay/`，或改用 roslibjs 自研单页（完全离线） |
| 车端 `eth0` 与 WiFi 同网段 | 路由歧义 | §7 |

---

## 12. 附录：文件清单与命令速查

```
08_csi2rk_mipi_imx415/
├── rk/relay/                       # 中继端（板上 /root/rk/relay/）
│   ├── deploy_relay.sh             # 一键部署（幂等，含 DHCP）
│   ├── nginx-ros-relay.conf        # 站点 + WS 反代
│   ├── chrony-relay.conf           # 中继 NTP 源（可选）
│   ├── dnsmasq-ros-relay.conf      # DHCP（车端零配置的关键）
│   ├── nftables.conf               # 备用（本内核不支持，已 mask）
│   ├── index.html                  # 占位页
│   └── jetson/                     # 车端（板上 ~/ros_relay_prep/ 与 ~/ros_relay/）
│       ├── install_user_side.sh    # ★ 用户态安装（无 sudo）
│       ├── start_bridge.sh         # ★ 启动 bridge（CMAKE_PREFIX_PATH 必带）
│       ├── ros_ip_env.sh           # ROS_IP 自动选择
│       ├── web_goal_bridge.py      # /goal_pose -> move_base
│       ├── apply_prep.sh           # 可选：需 sudo 的“正统安装”
│       ├── 70-ros-relay-net.rules  # 可选：udev 固定名
│       └── chrony-client.conf      # 可选：对时
└── tools/
    ├── pc_http_proxy.py            # PC 侧跳板代理（仅开发期）
    └── debs/                       # 离线 arm64 deb
        ├── ros-noetic-foxglove-bridge_0.8.4_arm64.deb
        └── ros-noetic-ros-babel-fish_0.9.3_arm64.deb
```

```bash
# 中继状态
ssh afc03 'ip -br addr; systemctl is-active nginx chrony avahi-daemon dnsmasq; curl -s http://127.0.0.1/relay-health'
# 车端状态（bridge 与 bridge 端口）
ssh ros 'ss -lnt | grep 8765; ip -4 addr show | grep 192.168.100; tail -3 ~/ros_relay/bridge.log'
# 离线包在不在
ssh ros 'ls -l ~/ros_ext/opt/ros/noetic/lib/foxglove_bridge/foxglove_bridge'
# 链路
ssh afc03 'ping -c3 192.168.100.1'
```
