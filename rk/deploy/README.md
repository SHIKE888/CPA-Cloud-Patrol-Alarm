# RK3576 端部署说明（FPGA MIPI → RK → HDMI）

> 适用板卡：MLK-AFC03（RK3576J + 安路 PH1A90SEG324 异构核心板）
> 目标：FPGA 通过内部 MIPI 4-lane 把画面送到 RK3576 的 **MIPI CSI3**，
> RK 侧由 `milianke_mipi` 虚拟摄像头驱动接管，交给 CIF/ISP/VPSS 后从 **HDMI 2.1 输出**。

---

## 0. 目录说明

```
rk/
├── boot.img            内核 + 设备树 + 驱动（已内置 milianke_mipi）
├── driver/             milianke_mipi.c 驱动源码 + Kconfig/Makefile 补丁位置
│   ├── milianke_mipi.c
│   ├── Kconfig         内核 media/i2c/Kconfig 的对应片段（参考）
│   ├── Makefile        内核 media/i2c/Makefile 的对应片段（参考）
│   └── build_module.sh 独立编译 .ko（可选）
├── dts/                AFC03 的 RK3576 设备树（含 FPGA 虚拟摄像头节点）
│   ├── rockchip/
│   │   ├── mlk-rk03-rk3576-linux.dts       主 dts
│   │   ├── rockchip/rk03/csi-imx415-2.dtsi ← FPGA 虚拟摄像头的关键节点
│   │   ├── rockchip/rk03/HDMI.dtsi         ← HDMI 输出使能
│   │   └── ...
│   └── ...
└── deploy/
    ├── rk_mipi_selftest.sh   链路自检（不依赖显示器）
    └── test_hdmi.sh          HDMI 出图 / 抓帧
```

---

## 1. 首次刷机（只需要做一次）

### 1.1 烧写 Debian 固件
从米联客官网下载 RK3576 Debian 镜像（AFC03/RK03 通用）：
> https://www.uisrc.com/t-6245.html

用瑞芯微 **RKDevTool**（Windows）或 `upgrade_tool`（Linux）整机烧写，
烧写时 **不要按住 BOOT 键**，正常上电即可。

### 1.2 升级 boot 分区（关键）
本项目内核对 `boot.img` 做了两件事：
1. 内置 `milianke_mipi` 虚拟摄像头驱动；
2. 设备树里打开了 FPGA 虚拟摄像头节点
   （`i2c9/fpga@1a` + `csi2_dphy3` + `mipi3_csi2` + `rkisp_vir2`，并打开了 HDMI）。

只刷 boot 分区即可，其它分区保持 1.1 的固件不变。

**方式 A：板上直接替换（推荐，最省事）**
```bash
# 把 boot.img 拷到板子, 例如 /root/boot.img
ls -l /dev/disk/by-partlabel/          # 找到 boot 分区, 通常是 mmcblk0p3 之类
blkid | grep -i boot                    # 确认分区
dd if=/root/boot.img of=/dev/disk/by-partlabel/boot bs=4M conv=fsync
sync && reboot
```

**方式 B：Windows 上用 RKDevTool**
1. 打开 RKDevTool → 「下载镜像」页
2. 地址/路径方式选择 `boot.img`，分区名填 `boot`
3. 设备进入 loader 模式后点「执行」

**方式 C：用设备树自行重新打包 update.img**
```bash
# 把 rk/dts/rockchip 覆盖到 SDK 的 kernel/arch/arm64/boot/dts/rockchip/
# 再把 rk/driver/milianke_mipi.c 放入 kernel/drivers/media/i2c/，
# 按 Kconfig / Makefile 片段添加 CONFIG_VIDEO_MILIANKE_FPGA_VIRTUAL=y
./build.sh kernel        # 重新编译内核与 dtb
./build.sh updateimg     # 生成 update.img 后整机升级
```

### 1.3 加跳线帽
按 AFC03 硬件手册「RK3576J-PH1A90SEG324-MIPI 交互」章节，装上 MIPI 内部互联的
跳线帽（让 FPGA 的 MIPI D-PHY 输出真正接到 RK 的 CSI3 输入）。

---

## 2. 上电顺序

```
1) 先烧写 FPGA bit (见 ../README.md)
2) RK3576 上电启动 (FPGA 侧电源由 RK 侧最后一级电源使能, 所以 RK 必须先起)
3) 运行 gst 命令, 驱动的 s_stream() 会把 mipi-en GPIO 拉高
   -> FPGA I_dsi_en 变高 -> D-PHY 开始发送 HS 数据
```

> 注意：**FPGA 的 D-PHY 只有在 `I_dsi_en` 为高时才开始发数据**，
> 而 `I_dsi_en` 由 RK 的 `gpio1 RK_PD0` 控制。所以「先开 FPGA、再开 RK」时，
> 必须等到 RK 侧真的开始采集（跑 gst / 打开摄像头 App）画面才会出现。

---

## 3. 跑测试

```bash
# 3.1 拷贝脚本到板子
scp -r deploy/ root@<板子IP>:/root/deploy/
ssh root@<板子IP>
cd /root/deploy && chmod +x *.sh

# 3.2 链路自检 (先确认 FPGA->RK 数据通路)
./rk_mipi_selftest.sh

# 3.3 出图到 HDMI
./test_hdmi.sh                      # 自动找节点 + kmssink 全屏显示
./test_hdmi.sh /dev/video22         # 指定节点

# 3.4 抓一帧存档 (方便离线确认画面)
./test_hdmi.sh /dev/video22 save    # 生成 /root/frame.png
```

原始的等价命令（与米联客教程一致）：
```bash
gst-launch-1.0 v4l2src device=/dev/video22 ! kmssink
```

#### 不想接显示器？推到网络上看
见 **[`../web/README.md`](../web/README.md)**：
```bash
cd /root/web && ./start_webstream.sh          # 推流到 <板子IP>:9012
# PC 双击 mipi_viewer.html, 地址填 <板子IP>:9012 -> 看画面 + 在线调参
```

---

## 4. 常见问题

| 现象 | 排查方向 |
|------|----------|
| 找不到 `/dev/video*` 采集节点 | `boot.img` 没刷 / 跳线帽没装。看 `dmesg \| grep milianke` |
| `v4l2-ctl --list-formats-ext` 为空 | FPGA bit 未烧写，或 `I_dsi_en` 一直为低（RK 未开流） |
| 能抓到帧但 HDMI 黑屏 | `cat /sys/class/drm/card*-HDMI-A-1/status`，确认显示器 connected；用 `modetest -c` 查 connector-id 后 `kmssink connector-id=<id>` |
| 画面花屏 / 撕裂 | 确认 FPGA 侧输出的分辨率与 RK 驱动 `DUMMY_WIDTH/HEIGHT` 一致（默认 1920x1080）|
| 只有一半画面 / 每行错位 | FPGA 侧 `ui_dbuf` 的 `W_XSIZE/R_XSIZE` 与分辨率的推导关系被破坏（本项目已用 localparam 自动推导）|
| 内核 log 报 `no link` / `dphy not ready` | MIPI 内部互联跳线帽方向装反，或 FPGA 侧 `pll_dsi` 未锁定 |

---

## 5. 驱动参数（想改分辨率时看这里）

`rk/driver/milianke_mipi.c` 顶部：

```c
#define DUMMY_WIDTH      1920
#define DUMMY_HEIGHT     1080
#define DUMMY_FPS_NUM    1
#define DUMMY_FPS_DEN    60
#define DUMMY_LINK_FREQ  500000000
#define DUMMY_PIXEL_RATE 148500000
```

必须与 FPGA 侧 `system_top.v` 里的 `H_ACTIVE / V_ACTIVE / csi2_frame_tx.DT` 保持一致。
