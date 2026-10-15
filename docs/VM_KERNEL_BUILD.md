# RK3576 内核编译说明 + 回溯备份规程

> 适用项目：`08_csi2rk_mipi_imx415`（MLK-AFC03：RK3576J + 安路 PH1A90 FPGA）
> 编写时间：2026-10-15
> 触发原因：`milianke_mipi.c` 的颜色空间修正（SRGB → REC709/limited）必须**重编内核**才生效（该驱动是内置 `=y`）
>
> **状态：本文件只是说明 + 规程，尚未对内核做任何改动。**

---

## 0. 一句话速查

```powershell
# 进虚拟机（必须带 -i，本机 ssh config 里没有这台机的别名）
ssh -i $env:USERPROFILE\.ssh\key\afc03_ed25519 uisrc@192.168.65.128

# 或跑本地脚本（推荐，避免 PowerShell → ssh 的参数转义/编码坑）
cd C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415
powershell -ExecutionPolicy Bypass -File tools\vmsh.ps1 -File tools\<你的脚本>.sh
```

内核与工具链就在虚拟机里，**不需要在 Windows 上装任何交叉编译环境**。

---

## 1. 环境事实

### 1.1 虚拟机

| 项 | 值 |
|---|---|
| 访问 | `uisrc@192.168.65.128`（TCP 22） |
| hostname / 系统 | `jammy` / Ubuntu 22.04（VM 自身内核 6.8.0-49-generic） |
| 规格 | 16 vCPU / 16 GB RAM；`/dev/sda3` 294 G（已用 111 G，**可用 169 G**） |
| .vmx | `F:\Project Files\FPGA\03_MLK_AFH03_AFC03\uisrc-ubuntu22.04\uisrc-ubuntu22.04.vmx`（安路 uisrc 系统盘） |
| 网络 | **NAT**（vmnet8，宿主侧 192.168.65.1）；MAC `00:0c:29:55:2e:79` |
| 共享目录 | 宿主 `F:\Project Files\FPGA\03_MLK_AFH03_AFC03` ↔ guest `/mnt/hgfs/MLK_AFH03_AFC03`（读写） |
| 免密 | 宿主公钥 `~/.ssh/key/afc03_ed25519.pub` 已写入 guest `~/.ssh/authorized_keys`（2026-10-15 配置） |

**注意**：`~/.ssh/config` 里**没有** 192.168.65.128 的别名，所以每次都要带 `-i`，否则会退回密码认证。

### 1.2 SDK / 内核 / 工具链

| 项 | 路径 |
|---|---|
| SDK 根 | `/home/uisrc/mlk-sdk-3576-v1.1.0`（原始压缩包 `~/mlk-sdk-3576-v1.1.0.tar.gz`，26,912,405,818 B） |
| 内核树 | `<SDK>/kernel-6.1`（`<SDK>/kernel` 是软链，Linux **6.1.99**） |
| 体积 | 全量 2.9 G；排除编译产物后源码 **2.0 G** |
| 板级 defconfig | `<SDK>/device/rockchip/.chips/rk3576/mlk_afh03_rk3576_defconfig`（`device/rockchip/.chip` → `.chips/rk3576`） |
| 内核基础 defconfig | `<SDK>/kernel-6.1/arch/arm64/configs/rockchip_linux_defconfig` |
| 内核 config 片段 | `<SDK>/kernel-6.1/arch/arm64/configs/rk3576.config` |
| 交叉工具链 | `<SDK>/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-`（gcc 10.3.1 / binutils 2.36.1） |
| 驱动（要改的） | `<SDK>/kernel-6.1/drivers/media/i2c/milianke_mipi.c` |
| 关键配置 | `CONFIG_VIDEO_MILIANKE_FPGA_VIRTUAL=y`，定义在 `rockchip_linux_defconfig` **第 333 行** ⇒ 驱动是**内置**，且**重跑 defconfig 不会丢** |
| 产物 | `<SDK>/kernel-6.1/boot.img`（`<SDK>/output/firmware/boot.img` 是软链） |
| 编译日志 | `<SDK>/output/sessions/<时间戳>/`（含 `10-kernel-build.log`、`build.log`、`final.env`） |

### 1.3 编译产物现状（2026-10-09 那次）

| 文件 | 大小 | 时间 |
|---|---|---|
| `arch/arm64/boot/Image` | 39,778,816 B | 2026-10-09 16:26:35 |
| `arch/arm64/boot/Image.lz4` | 17,140,008 B | 2026-10-09 16:26:40 |
| `vmlinux` | 179,322,864 B | 2026-10-09 16:26:35 |
| `resource.img` | 5,712,384 B | 2026-10-09 22:54:26 |
| **`boot.img`** | **45,783,552 B** | **2026-10-09 22:54:26** |
| `drivers/media/i2c/milianke_mipi.o` | 70,216 B | 2026-09-21 09:27（**原始 .o，未重编过**） |

> `CONFIG_DEBUG_INFO=y`，所以 `vmlinux` 有 179 MB —— 全量重编会比较久，**务必用增量编译**。

---

## 2. 动手前先认领基线（已核对完成）

| 基线 | 文件 | 大小 | MD5 |
|---|---|---|---|
| **A. 板上现役**（= SDK 那份） | `<SDK>/kernel-6.1/boot.img` | 45,783,552 | `0deb3ac78d3ce5861b847f31d88e9414` |
| **B. 出厂原始**（早期另一次构建） | 本项目 `rk/boot.img` | 45,788,672 | `2a9c2b3a211b7967310d4e4d8e70274c` |

**核对证据**

1. 板上 `cat /proc/version` → `#4 SMP Fri Oct 9 16:26:24 CST 2026`，编译器 `aarch64-none-linux-gnu-gcc 10.3.1`，编译账户 `uisrc@jammy`
   ⇒ 板上内核就是**虚拟机里 10-09 那次编译**的产物。
2. 读板上 boot 分区前 45,783,552 字节的 md5 = `0deb3ac78d3ce5861b847f31d88e9414`
   ⇒ 与 SDK `boot.img` **逐字节一致**，与 `rk/boot.img` 不同。

**结论**：回溯基线用 **A（`0deb3ac7…`）**；B 只作为"厂商出厂镜像"的额外存档，不作为回滚首选。

复现校验命令：

```powershell
# 板上 boot 分区（只读，无害）
ssh afc03 "dd if=/dev/disk/by-partlabel/boot bs=512 count=89421 2>/dev/null | md5sum"
# 虚拟机里的候选镜像
ssh -i $env:USERPROFILE\.ssh\key\afc03_ed25519 uisrc@192.168.65.128 `
  "head -c 45783552 /home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1/boot.img | md5sum"
```

---

## 3. 【强制】改动前的回溯备份规程

> **原则：没有做完第 3 步，不允许碰内核树里任何文件。**
> 内核树 **不是 git 仓库**（`git status` 报 `not a git repository`），所以必须手工备份。

### 3.1 备份目录布局

```
/home/uisrc/kernel-backup/<YYYYMMDD-HHMMSS>/
├── BASELINE.txt              # 时间/主机/被改文件与 boot.img 的 md5 + mtime
├── files/
│   ├── milianke_mipi.c.orig  # 逐文件原样副本（cp -a 保时间戳）
│   └── MANIFEST.md5          # 对应 md5 清单，用于 md5sum -c 校验
├── kernel-6.1-src.tgz        # 全树源码归档（排除编译产物）
├── kernel-6.1-src.tgz.sha256
├── .config.before            # 改动前内核配置
├── boot.img.known-good       # 现役可回刷镜像（md5 必须 = 0deb3ac7…）
└── board-boot-partition.img  # 板上 64 MB 整分区 dump（字节级可回刷）
```

### 3.2 一键备份（脚本已就绪：`tools/vm_backup_kernel.sh`）

```powershell
cd C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415
powershell -ExecutionPolicy Bypass -File tools\vmsh.ps1 -File tools\vm_backup_kernel.sh
```

脚本做的事如下（含基线自检：驱动必须是 stock、`boot.img` 必须等于板上现役那份）：

```bash
#!/bin/bash
set -e
SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
K="$SDK/kernel-6.1"
BK="$HOME/kernel-backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK/files"
echo "备份目录: $BK"

# --- 0) 基线记录 ---
{ echo "date: $(date -Is)"; echo "host: $(hostname) @ $(uname -r)"; echo;
  md5sum "$K/drivers/media/i2c/milianke_mipi.c" "$K/boot.img";
  ls -la --time-style=full-iso "$K/drivers/media/i2c/milianke_mipi.c" "$K/boot.img"; } \
  | tee "$BK/BASELINE.txt"

# --- 1) 逐文件原样副本 + 清单 ---
cp -a "$K/drivers/media/i2c/milianke_mipi.c" "$BK/files/milianke_mipi.c.orig"
( cd "$BK/files" && md5sum milianke_mipi.c.orig > MANIFEST.md5 )

# --- 2) 全树源码归档（约 2.0 GB 源码, gzip 后预计数百 MB）---
tar -czf "$BK/kernel-6.1-src.tgz" -C "$SDK" \
    --exclude='*.o' --exclude='*.a' --exclude='*.cmd' --exclude='*.ko' \
    --exclude='*.mod' --exclude='*.mod.*' --exclude='modules.*' --exclude='.tmp_*' \
    kernel-6.1
sha256sum "$BK/kernel-6.1-src.tgz" | tee "$BK/kernel-6.1-src.tgz.sha256"

# --- 3) 现役可回刷镜像 + 配置 ---
cp -a "$K/boot.img" "$BK/boot.img.known-good"
cp -a "$K/.config"  "$BK/.config.before"
md5sum "$BK/boot.img.known-good"      # 期望 0deb3ac78d3ce5861b847f31d88e9414

# --- 4) 板上 boot 分区整盘 dump（字节级回滚镜像）---
#     需要从虚拟机 scp 或直接用宿主 Windows 侧 ssh afc03 执行, 见 3.3
echo "完成。别忘了第 4 步的板上分区 dump。"
```

### 3.3 板上分区 dump（**回滚的最后一道保险**）

```powershell
# 宿主 Windows 侧执行（ssh afc03 已免密）
ssh afc03 "dd if=/dev/disk/by-partlabel/boot of=/root/boot.dump-20261015.img bs=1M count=64 conv=fsync; md5sum /root/boot.dump-20261015.img; ls -la /root/boot.dump-20261015.img"
# 拉回 Windows 再存一份
scp afc03:/root/boot.dump-20261015.img C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415\rk\backup\
```

> 板上 boot 分区 = `mmcblk0p3`，**64 MB**；`boot.img` 只有 45.78 MB，尾部是空洞。
> 所以回滚**用整分区 dump**，不要只写那个 45.78 MB 的文件（避免尾部残留旧数据）。

### 3.4 回滚（脚本已就绪：`tools/vm_restore_kernel.sh`）

```powershell
# 只回滚单文件（快，回滚后需重编）
powershell -ExecutionPolicy Bypass -File tools\vmsh.ps1 -File tools\vm_restore_kernel.sh `
  -ScriptArgs "/home/uisrc/kernel-backup/<时间戳> --file-only"

# 不加 --file-only 则连整棵内核树一起回滚（慢，需全量重编）
```

脚本逻辑（供审计）：

```bash
#!/bin/bash
# 用法: restore.sh <备份目录> [--file-only]
set -e
BK="${1:?用法: restore.sh <备份目录> [--file-only]}"
K=/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1

echo "== 1. 校验备份完整性 =="
( cd "$BK/files" && md5sum -c MANIFEST.md5 )

echo "== 2. 单文件回滚 =="
cp -a "$BK/files/milianke_mipi.c.orig" "$K/drivers/media/i2c/milianke_mipi.c"
md5sum "$K/drivers/media/i2c/milianke_mipi.c"   # 期望回到 15931acbe1f7f12332101a33ed9b2d20

if [ "$2" = "--file-only" ]; then echo "仅单文件回滚完成（记得重编）"; exit 0; fi

echo "== 3. 全树回滚 =="
mv "$K" "${K}.broken-$(date +%s)"
tar -xzf "$BK/kernel-6.1-src.tgz" -C /home/uisrc/mlk-sdk-3576-v1.1.0
echo "全树已回滚（新树无编译产物, 需全量重编）"
```

### 3.5 改动后的"证据快照"（同样强制）

改完立刻执行，便于日后审计与二分：

```bash
K=/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1
diff -u "$BK/files/milianke_mipi.c.orig" "$K/drivers/media/i2c/milianke_mipi.c" > "$BK/milianke_mipi.c.patch"
ls -la --time-style=full-iso "$K/arch/arm64/boot/Image" "$K/boot.img"
md5sum "$K/boot.img"        # 必须 ≠ 0deb3ac7…（否则说明根本没重编成功）
```

### 3.6 三种回滚粒度

| 粒度 | 操作 | 代价 |
|---|---|---|
| ① 源文件 | `restore.sh <BK> --file-only` 或直接 `cp files/*.orig` | 秒级，需重编 |
| ② 全树 | `restore.sh <BK>`（tar 解包） | 分钟级，需**全量**重编（DEBUG_INFO 下较久） |
| ③ 镜像 | 板上 `dd if=board-boot-partition.img of=/dev/disk/by-partlabel/boot` | 秒级，**不动源码**，最稳 |

**兜底**：原始 SDK 压缩包 `~/mlk-sdk-3576-v1.1.0.tar.gz`（26.9 GB）还在，理论上可抽取任何原始文件；但实测 45 秒内扫不到 `milianke_mipi.c`（该文件在包尾），**全量扫描/抽取需数分钟**，仅作最后手段。

---

## 4. 需要做的内核改动

### 改动 1（必做）：颜色空间 SRGB → REC709 + limited

**位置**：`kernel-6.1/drivers/media/i2c/milianke_mipi.c` 第 **140** 行（`milianke_get_fmt()` 内）。

**为什么**：FPGA 端 `rgb_to_yuv422_quad.v` 输出的是 **BT.709 + limited range(16~235)**
（`Y = 0.183R + 0.614G + 0.062B + 16`，系数和 0.859 = 219/255；抓帧实测 Y ∈ [22, 234]）。
驱动声明 `V4L2_COLORSPACE_SRGB`（含 full range 语义）⇒ rkcif/rkisp 按 full 解释 limited 数据
⇒ 黑电平抬高、白点只到 235、色度欠饱和 ⇒ **画面发灰发绿**。

**改动内容**

```diff
     fmt->format.field  = V4L2_FIELD_NONE;
-    fmt->format.colorspace = V4L2_COLORSPACE_SRGB;
+
+    /* FPGA 输出 = BT.709 + limited range(16~235), 不能声明成 SRGB(full range) */
+    fmt->format.colorspace   = V4L2_COLORSPACE_REC709;
+    fmt->format.ycbcr_enc    = V4L2_YCBCR_ENC_709;
+    fmt->format.quantization = V4L2_QUANTIZATION_LIM_RANGE;
+    fmt->format.xfer_func    = V4L2_XFER_FUNC_709;

     return 0;
 }
```

**推荐做法（比手改可靠）**

1. 先把 Windows 上那份"改好的参考版"推到虚拟机（在 **Windows** 侧执行）：

   ```powershell
   $k="$env:USERPROFILE\.ssh\key\afc03_ed25519"
   scp -i $k `
     C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415\rk\driver\milianke_mipi.c `
     uisrc@192.168.65.128:/tmp/milianke_mipi.ref.c
   ```

   然后在虚拟机里做完整 diff，**确认差异仅限颜色空间这一处**：

   ```bash
   diff -u "$BK/files/milianke_mipi.c.orig" /tmp/milianke_mipi.ref.c
   ```

   > Windows 侧参考版：`08_csi2rk_mipi_imx415/rk/driver/milianke_mipi.c`（就是你之前改好的那份）。
   > **必须**先 diff 确认它没有夹带其他改动，再覆盖。
2. 确认无误后：`cp` 覆盖内核树里的文件。
3. 立刻执行 §3.5 的 `diff -u` 存档。

### 改动 2（后续 Phase C，本次不做，仅登记）

为了多分辨率模式（1080p/720p/4K），驱动里这些硬编码要改成模式表：

| 行 | 内容 |
|---|---|
| 52–53 | `#define DUMMY_WIDTH 1920` / `DUMMY_HEIGHT 1080` |
| 54–55 | `DUMMY_FPS_NUM 1` / `DUMMY_FPS_DEN 60` |
| 57 | `DUMMY_LINK_FREQ 500000000` |
| 67 | `static const s64 link_freq_menu[] = { DUMMY_LINK_FREQ };` |
| 124–127 | `fse->min_width/max_width/min_height/max_height = DUMMY_*`（**min==max**，V4L2 会拒绝协商其它尺寸） |
| 390–395 | `v4l2_ctrl_new_int_menu(...)` 建 link_freq 控件 |

> 4K 还要注意：`DUMMY_LINK_FREQ` 与 FPGA 侧 PLL（VCO 1000 → 1200 MHz，clk1 125 → 150 MHz）必须同步改，否则 RK 侧 D-PHY 速率与 FPGA 发送不匹配。

---

## 5. 编译（命令已从 10-09 实际日志抄出）

日志原文（`output/sessions/2026-10-09_22-54-17/build.log`）：

```
make -C <SDK>/kernel/ -j17 CROSS_COMPILE=<SDK>/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu- ARCH=arm64 rockchip_linux_defconfig rk3576.config
make -C <SDK>/kernel/ -j17 CROSS_COMPILE=<...>/aarch64-none-linux-gnu- ARCH=arm64 mlk-afh03-rk3576-linux.img
...
+ mk-fitimage.sh kernel/boot.img device/rockchip/.chip/boot.its kernel/arch/arm64/boot/Image kernel/arch/arm64/boot/dts/rockchip/mlk-afh03-rk3576-linux.dtb kernel/resource.img
```

### 5.1 只改了驱动 → 只跑第二条（增量）

```bash
SDK=/home/uisrc/mlk-sdk-3576-v1.1.0
CC=$SDK/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-

make -C $SDK/kernel/ -j17 CROSS_COMPILE=$CC ARCH=arm64 mlk-afh03-rk3576-linux.img
```

这条会：重编被改的 `.o` → 重新链接 `vmlinux` → 出 `Image` / `Image.lz4` →
更新 `resource.img`（含 dtb/logo）→ 调 `mk-fitimage.sh` 打出 `boot.img` 和 `zboot.img`。

**不要**重跑第一条（`rockchip_linux_defconfig rk3576.config`）——它会**重新生成 `.config`**，
把任何手工 config 调整清掉。虽然 `CONFIG_VIDEO_MILIANKE_FPGA_VIRTUAL=y` 来自
`rockchip_linux_defconfig:333` 不会丢，但没必要冒这个险。

### 5.2 等价的 SDK 封装写法

```bash
cd $SDK && ./build.sh kernel        # 产物同样落到 kernel-6.1/boot.img
```

> `./build.sh kernel` 是 SDK 标准子命令（上次构建的日志就是 `10-kernel-build.log`）。
> 若报"未知选项"，直接用 §5.1 的两条 `make`，它们是从实际日志抄出的、必然可用。

### 5.3 产物

| 文件 | 说明 |
|---|---|
| `<SDK>/kernel-6.1/arch/arm64/boot/Image` | 未压缩内核 |
| `<SDK>/kernel-6.1/arch/arm64/boot/Image.lz4` | lz4 内核（zboot 用） |
| `<SDK>/kernel-6.1/resource.img` | dtb + logo |
| **`<SDK>/kernel-6.1/boot.img`** | **要刷的镜像**（FIT：Image + resource.img） |
| `<SDK>/kernel-6.1/zboot.img` | Image.lz4 + resource.img（另一路引导，一般不用） |

---

## 6. 取回 / 刷写 / 回滚

### 6.1 取回到 Windows

```powershell
$k="$env:USERPROFILE\.ssh\key\afc03_ed25519"
scp -i $k uisrc@192.168.65.128:/home/uisrc/mlk-sdk-3576-v1.1.0/kernel-6.1/boot.img `
    C:\Users\shike\Desktop\csi2rk2hdmi\08_csi2rk_mipi_imx415\rk\boot.rec709.img
Get-FileHash C:\...\rk\boot.rec709.img -Algorithm MD5     # 记录 fingerprint
```

### 6.2 刷板（板上 `ssh afc03`）

```bash
# 刷前先 dump 现役分区（= 回滚镜像, 见 §3.3）
dd if=/dev/disk/by-partlabel/boot of=/root/boot.before-rec709.img bs=1M count=64 conv=fsync

# 刷入新镜像
dd if=/root/boot.rec709.img of=/dev/disk/by-partlabel/boot conv=fsync && sync && reboot
```

### 6.3 回滚

```bash
dd if=/root/boot.before-rec709.img of=/dev/disk/by-partlabel/boot conv=fsync && sync && reboot
```

---

## 7. 验证清单

| # | 检查 | 期望 |
|---|---|---|
| 1 | 新 `boot.img` md5 | **≠** `0deb3ac7…`（若相同说明没编进去） |
| 2 | 板上 `cat /proc/version` | `#N` 编号与编译时间变化（原来是 `#4 SMP Fri Oct 9 16:26:24 CST 2026`） |
| 3 | 板上 `dmesg \| grep milianke` | 出现 `milianke MIPI sensor registered: … (FPGA CSI-2, 1920x1080@60fps, link-freq=500000000, mipi-en=yes)` |
| 4 | 颜色 | 画面不再发灰发绿；抓帧 Y 范围仍应是 16~235 的 limited（数据没变，变的是 RK 的解释方式） |
| 5 | 过曝 | 若仍过曝，属 IMX415 曝光/增益偏高，去改 FPGA 侧 `ui_imx415_reg.v` / `ui_ae_set`，**不是**内核问题 |
| 6 | 回滚演练 | 用 §6.3 刷回 `boot.before-rec709.img`，`/proc/version` 恢复 `#4 …` |

---

## 8. 禁止事项 / 已知坑

1. **内核树不是 git 仓库** ⇒ 没有任何"撤销"按钮，一切靠 §3 的备份。
2. **不要** `./build.sh clean-kernel`：会删掉整棵树的编译产物，之后要**全量重编**（`DEBUG_INFO=y`，很慢）。
3. **不要**在没备份 `.config` 的情况下跑 `rockchip_linux_defconfig` / `menuconfig`。
4. **不要** `git init` 那棵 2.9 G 的树（会引入巨大的 `.git` 并把 `.o` 全纳入）。
5. PowerShell → `ssh.exe` 会**重新分词**参数：`find ... \( -name "*.c" \)` 这类会碎掉；
   用 `tools/vmsh.ps1`（base64 传脚本正文）绕开。同理，含中文的参数在 PowerShell 5.1 下易乱码。
6. `ssh` 到虚拟机**必须** `-i $env:USERPROFILE\.ssh\key\afc03_ed25519`（config 里没别名），否则退回密码认证。
7. 用 `create_file` 在本仓库新建的 `.sh` / `.py` 可能是 **CRLF**；`vmsh.ps1` 已自动把 CRLF 归一成 LF，手工 scp 脚本时要注意。
8. 虚拟机是 **NAT** 网络：从 Windows 连它走 `192.168.65.128`；反过来从虚拟机连 Windows 要查 vmnet8 的宿主地址（`192.168.65.1`），别和板子的 `192.168.137.100` 搞混。
9. 板子（`ssh afc03`，`192.168.137.100`）与虚拟机是**两套独立系统**，别把 `rk/` 下的部署脚本跟 SDK 编译混在一起。

---

## 9. 配套工具（本次为探查新增，可复用）

| 文件 | 用途 |
|---|---|
| `tools/vmsh.ps1` | 在虚拟机执行本地 `.sh`（UTF-8 + LF 归一 + base64 传输，规避转义/编码问题） |
| `tools/vm_probe_env.sh` | 找内核源码 / 工具链 / 共享目录 / 磁盘 |
| `tools/vm_probe_sdk.sh` | SDK 结构、构建入口、已编译产物、配置 |
| `tools/vm_probe_driver.sh` | 驱动现状（颜色空间/分辨率硬编码）、defconfig、`build.sh --help` |
| `tools/vm_probe_build.sh` | boot.img 打包配方、体积统计、上次构建日志 |
| `tools/vm_probe_build2.sh` | `build.sh` 子命令、boot.img 指纹 |
| `tools/vm_probe_patch.sh` | 待改处原文行号、SDK 原始 tarball 可用性 |
| `tools/vm_probe_cfg.sh` | `CONFIG_VIDEO_MILIANKE_FPGA_VIRTUAL` 来源、产物时间线 |
| **`tools/vm_backup_kernel.sh`** | **【强制】改动前回溯备份**（基线记录 + 逐文件副本 + 全树归档 + boot.img/.config） |
| **`tools/vm_restore_kernel.sh`** | **回滚**（`--file-only` 单文件 / 全树） |

---

## 10. 附录：事实速查

```text
虚拟机         uisrc@192.168.65.128   (jammy, Ubuntu 22.04, 16C/16G)
SDK            /home/uisrc/mlk-sdk-3576-v1.1.0
内核树         <SDK>/kernel-6.1       (Linux 6.1.99; 非 git 仓库)
驱动           <SDK>/kernel-6.1/drivers/media/i2c/milianke_mipi.c
               stock: 494 行 / 12,992 B / md5 15931acbe1f7f12332101a33ed9b2d20 / 2026-04-27 19:44
工具链         <SDK>/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu
编译目标       make -C <SDK>/kernel/ -j17 CROSS_COMPILE=<CC> ARCH=arm64 mlk-afh03-rk3576-linux.img
产物           <SDK>/kernel-6.1/boot.img           45,783,552 B
现役镜像 md5   0deb3ac78d3ce5861b847f31d88e9414   (= 板上 boot 分区前 45,783,552 B)
出厂镜像 md5   2a9c2b3a211b7967310d4e4d8e70274c   (本项目 rk/boot.img, 2026-09-10)
板上 boot 分区 /dev/disk/by-partlabel/boot (mmcblk0p3, 64 MB)
备份根目录     /home/uisrc/kernel-backup/
```
