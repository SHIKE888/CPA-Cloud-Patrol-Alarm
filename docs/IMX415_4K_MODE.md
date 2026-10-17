# IMX415 4K 模式配置（厂商参考 + 落地改动清单）

> ⚠ **2026-10-18 V39 更正**：本文下面的寄存器表是厂商 **4K30** 参考（VMAX=4503/
> HMAX=533/SYS_MODE=0x08）。本工程最终为了 1000Mbps 链路，实际采用的是
> **4K25 参数：VMAX=3420 (0x5C/0x0D)、HMAX=861 (0x5D/0x03)、SYS_MODE=0x05**
> （891Mbps），VTC 时序 2652×2225。阅读差异表时以 V39 的
> `fpga/uisrc/03_ip/ui_imx415_cfg/ui_imx415_reg.v` 为准。

> 来源：`07_异构方案/AFC03_IMX415_PCIE_X1/.../IMX415_PCIE_X1/uisrc/03_ip/ui_imx415_cfg/ui_imx415_reg.v`
> （厂商 PCIe 方案的工程里带 `MODE` 参数，0=1080p binning / 1=4K all-pixel / 2=720p。
> 工程目录名就叫 `imx415_pcie_4k_Runs`，说明 4K 是厂商验证过的。）

---

## 0. 结论（为什么我们的 4K 出不来）

我们现在跑的是 **2×2 binning** 读出模式：

| 寄存器 | 我们现在 | 含义 |
|---|---|---|
| `0x3020` HADD | `0x01` | **1 = 2x2 binning** |
| `0x3021` VADD | `0x01` | 1 = 2x2 binning |
| `0x3022` ADDMODE | `0x01` | 1 = binning |

binning 后输出 **~1932×1092**，实测 `0xD4/0xD5` = **486 组 × 4 px = 1944 px/行** ✓ 完全对上。

于是：
```verilog
// ui_image_correction.v
assign O_raw_tlast = V_valid && (h_cnt == img_width_4x) && I_raw_tvalid_d;
```
- 1080p：`img_width_4x = 1920>>2 = 480 ≤ 486` → `tlast` 正常 ✓
- 4K：`img_width_4x = 3840>>2 = 960 > 486` → **`tlast` 永远不触发 → 下游一帧都拼不出来** ✗

⇒ **4K 必须先让传感器切到 all-pixel 读出模式（`0x3020/21/22 = 0x00`）**，
输入行变成 ~966 组，`h_cnt` 才够到 960。

---

## 1. 4K 与 1080p 的全部寄存器差异（27 条）

| idx | 寄存器 | 1080p(binning) | **4K(all-pixel)** | 说明 |
|---:|---|---|---|---|
| 4 | `0x3008` | `0x5D` | **`0x54`** | BCWAIT_TIME |
| 6 | `0x300A` | `0x42` | **`0x3B`** | CPWAIT_TIME |
| 10 | `0x3020` | `0x01` | **`0x00`** | HADD: 0=no-add(4K), 1=2x2-binning |
| 11 | `0x3021` | `0x01` | **`0x00`** | VADD |
| 12 | `0x3022` | `0x01` | **`0x00`** | ADDMODE |
| 14 | `0x3024` | `0xEB` | **`0x97`** | VMAX[7:0] |
| 15 | `0x3025` | `0x08` | **`0x11`** | VMAX[15:8] → **4K VMAX = 0x1197 = 4503 行** |
| 17 | `0x3028` | `0x1E` | **`0x15`** | HMAX[7:0] → **4K HMAX = 0x0215 = 533** |
| 24 | `0x3033` | `0x05` | **`0x08`** | SYS_MODE |
| 51 | `0x3090` | `0x20` | **`0x10`** | GAIN_PGC_0 初值（后续会被 AE 通道覆盖） |
| 64 | `0x30D9` | `0x02` | **`0x06`** | DIG_CLP_VSTART |
| 65 | `0x30DA` | `0x01` | **`0x02`** | DIG_CLP_VNUM |
| 70 | `0x3118` | `0xC6` | **`0xB4`** | INCKSEL3 |
| 72 | `0x311A` | `0xE7` | **`0xFC`** | INCKSEL4 |
| 179 | `0x4004` | `0xC0` | **`0x00`** | TXCLKESC_FREQ |
| 181 | `0x400C` | `0x00` | **`0x01`** | INCKSEL6 |
| 182 | `0x4018` | `0x7F` | **`0x9F`** | TCLKPOST |
| 184 | `0x401A` | `0x37` | **`0x57`** | TCLKPREPARE |
| 186 | `0x401C` | `0x37` | **`0x57`** | TCLKTRAIL |
| 188 | `0x401E` | `0xF7` | **`0x87`** | TCLKZERO[7:0] |
| 189 | `0x401F` | `0x00` | **`0x01`** | TCLKZERO[15:8] |
| 190 | `0x4020` | `0x3F` | **`0x5F`** | THSPREPARE |
| 192 | `0x4022` | `0x6F` | **`0xA7`** | THSZERO |
| 194 | `0x4024` | `0x3F` | **`0x5F`** | THSTRAIL |
| 196 | `0x4026` | `0x5F` | **`0x97`** | THSEXIT |
| 198 | `0x4028` | `0x2F` | **`0x4F`** | TLPX |
| 200 | `0x4074` | `0x01` | **`0x00`** | INCKSEL7 |

> 其余 175 条两个模式**完全相同**（已逐条 diff 验证，差异只有上面这些 + 增益初值）。
> `REG_SIZE = 201` 两个模式一样。

**关键含义**：`0x4004..0x4074` 这些是 **MIPI D-PHY 的发送时序**，4K 下不一样
⇒ **传感器的 lane 速率在 4K 下会变** ⇒ FPGA 侧的 D-PHY RX 必须重新锁定。

---

## 2. 厂商在 4K 下用的几何参数（`imx415_pcie_top.v` 的 mode LUT）

```verilog
// cam_mode -> { img_width, img_height, crop_v_start, crop_v_end, crop_h_end }
2'd0: 1920, 1080, v_start=19,   v_end=1100, h_end=481   // 1080p 2x2 binning
2'd1: 3840, 2160, v_start=35,   v_end=2196, h_end=961   // 4K full resolution
2'd2: 1280,  720, v_start=35,   v_end=756,  h_end=321   // 720p
```
- `crop_h_end`：1080p = 481、4K = 961 —— 和我们现在的 `img_width>>2`（480 / 960）**等价** ✓
- 4K 有效行 = 2196-35 = **2161 行**（注释：首行必须偶数，否则 Bayer 相位错）
- 帧长：`HMAX=533 @74.25MHz = 7.18us`；`4503 行 × 7.18us = 32.3ms` ⇒ **3200/32.3 ≈ 30.9 fps**
  ⇒ 4K 的自然帧率就是 **~31fps**，所以厂商做的是 **4K30**。

---

## 3. 落地改动清单（我们工程要做到 4K 需要改的东西）

| # | 文件 | 改动 |
|---|---|---|
| A | `ui_imx415_reg.v` | 加 `MODE` 输入 + 上表 27 条条件项（直接以厂商文件为基准，保留我们的增益初值 `0x30`） |
| B | `ui_cfg_imx415.v` | 加 `I_cam_mode` / `I_full_reload`；**收到 reload 时把相位强制切回主表**（`O_cfg_done=0, O_cfg_done_r=0, O_ae_cfg_done=0, reg_index=0`，**不要**推 `TS_S`——`REG_DATA` 是寄存器滞后一拍）；把 MODE 透给 ROM |
| C | `cam_param.v` | **`VMAX` 必须跟着模式变**（binning 2283 / 4K 4503），现在是 `#()` 常量；曝光换算与钳位都要用它 |
| D | `system_top.v` | ① 把 `S_res_mode` 同步到 24MHz 域给 `ui_cfg_imx415.I_cam_mode`；② `S_res_chg` **延时 ~32 拍后再**产生 `I_full_reload`（保证同步后的 mode 已稳定）；③ 复位窗从 80ms 拉长到 **≥300ms**（要覆盖传感器全表重写 ~78ms + 传感器重新锁相 + 几帧）；④ 复位窗内**也要复位 D-PHY RX**（lane 速率会变）——它在 25MHz 域异步复位，各域同步器会被冻结但窗口过后会自行释放，不会死锁 |
| E | `mipi_webstream.py` | `CAM_VMAX` / `CAM_T_LINE_US` 按模式取（4K: 4503 / 7.18us）；`/api/modes` 的 4K30 标记改为可用 |

### 顺序要求（重要）
`S_res_chg` 触发两件事：**视频通路复位窗** 和 **传感器全表重写**。
两者都要覆盖整个传感器重新配置过程，所以窗口必须 ≥ 全表重写耗时（201 × 385us ≈ 78ms）+ 余量。

### 风险与回退
- D-PHY RX 复位是新增的：`S_hs_rx_clk` 由它恢复，复位期间各域同步器冻结（不会死锁，
  窗口过后自然释放），但要实测确认。
- 保留 `RES_RST_TX_SIDE` 式的一键回退开关。
- **默认模式保持 1080p**，改动不影响现有可用状态。
