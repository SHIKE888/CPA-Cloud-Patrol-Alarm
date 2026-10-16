# IMX415 4K 模式 —— 真正漏掉的"档次"：链路速率 (V27)

> 结论一句话：**4K 之前一直不出图，根因是把 MIPI 链路速率从 891 Mbps 抬到了 1485 Mbps。**
> 手册 P48 的档位表里，同样 3840×2160 有多种速率档可选，**用 891 Mbps 这一档即可**，
> 此时链路速率与已经稳定工作的 1080p **完全一致**，D-PHY 不需要变速、也没有 deskew burst 问题。

---

## 1. 手册 P48「Readout Drive mode / Operating mode」档位表

IMX415 的 all-pixel（全像素）3840×2160 读出，**4 lane** 下可用档位：

| Data rate [Mbps/lane] | SYS_MODE | AD/输出位宽 | 最高帧率 | INCK [MHz] | 1H 周期 [Clock] |
|---|---|---|---|---|---|
| 2376 | 0 | 10/10 | 90.9 | 27, 37.125, 74.25 | 365 |
| 2079 | 2 | 10/10 · 12/12 | 82.9 · 60.3 | 27, 37.125, 74.25 | 400 · 550 |
| 1782 | 4 | 10/10 · 12/12 | 72.4 · 60.3 | 27, 37.125, 74.25 | 458 · 550 |
| **1485** | **8** | 10/10 | **61.6** | 27, 37.125, 74.25 | **538** ← 厂商给的 4K 档 |
| 1440 | 8 | 10/10 · 12/12 | 60.4 · 51.1 | 24, 72 | 532 · 629 |
| 1188 | 6 | 10/10 · 12/12 | 51.5 · 43.3 | 24, 27, 37.125, 72, 74.25 | 644 · 766 |
| **891** | **5** | 10/10 · 12/12 | **38.5** · 32.4 | 27, 37.125, **74.25** | **861** · 1022 ← **本次采用** |
| 720 | 9 | 10/10 · 12/12 | 31.6 · 26.5 | 24, 72 | 1017 · 1210 |
| 594 | 7 | 10/10 · 12/12 | 26.2 · 22.0 | 27, 37.125, 74.25 | 1265 · 1506 |

* 所有 all-pixel 档位的 **1V period = 2238 XHS**（即 VMAX 下限 2238）。
* 2 lane 另有独立档位表（2079 / 1782 / 1440 / 1188 / 891 / 720 / 594）。

### 关键事实

1. `SYS_MODE (0x3033) [3:0]` = **"Output IF mode setting"，就是链路速率档**；反射时机 = **`S`**（须在 standby 期间写）。
2. **1080p（2×2 binning）用的是 `SYS_MODE = 5` ⇒ 891 Mbps/lane**（我们表里原本就是这个值）。
3. **厂商给的 4K 表用 `SYS_MODE = 8` ⇒ 1440/1485 Mbps/lane** ⇒ lane 速率提升 **~1.67 倍**，
   D-PHY 时钟从 445.5 MHz 跳到 742.5 MHz。
4. 手册明确：**"When operating at or above 1440 Mbps, this Sensor transmits the initial deskew burst."**
   —— 1485 Mbps ≥ 1440，传感器会在起始发 **deskew burst**，接收端必须支持。
5. 手册另注：**standby 取消后要等约 9 帧**才有稳定图像。

### 为什么 891 Mbps 对 4K 也够

```
3840 × 2160 × 25 fps × 10 bit = 2.07 Gbps
4 lane × 891 Mbps            = 3.56 Gbps      → 占用 58%，余量充足
```

而 1485 Mbps 档（5.94 Gbps）是为 61.6 fps 准备的，**我们用不到**（FPGA→RK 侧只能到 4K25）。

---

## 2. 因此 V27 的做法

**核心思路：4K 与 1080p 共用同一速率档（891 Mbps），只改"读出几何"部分。**

| 类别 | 寄存器 | 处理 |
|---|---|---|
| **真正属于 all-pixel 的差异** | `0x3020/21/22` HADD/VADD/ADDMODE = `0x00` | 保留按 MODE 区分 |
| | `0x3028/0x3029` HMAX = **861** (`0x35D`) | 按 MODE 区分（**新增 `0x3029=0x03`**） |
| | `0x3024/0x3025` VMAX = **3449** (`0xD79`) | 按 MODE 区分（原 4503） |
| | `0x30D9/0x30DA` DIG_CLP_VSTART/VNUM = `0x06`/`0x02` | 保留按 MODE 区分（手册 P69 确认 6/2 = all-pixel） |
| **与速率绑定 → 改回 891 档** | `0x3033` SYS_MODE = `0x05` | ★★ 关键 |
| | `0x3008` BCWAIT_TIME = `0x5D` | 去条件 |
| | `0x300A` CPWAIT_TIME = `0x42` | 去条件 |
| | `0x3118` INCKSEL3 = `0xC6`、`0x311A` INCKSEL4 = `0xE7`、`0x400C` INCKSEL6 = `0x00`、`0x4074` INCKSEL7 = `0x01` | 去条件 |
| | `0x4004/0x4018/0x401A/0x401C/0x401E/0x401F/0x4020/0x4022/0x4024/0x4026/0x4028` (TXCLKESC_FREQ, TCLKPOST, TCLKPREPARE, TCLKTRAIL, TCLKZERO, THSPREPARE, THSZERO, THSTRAIL, THSEXIT, TLPX) | 去条件，全部用 891 档值 |
| **增益初值** | `0x3090` GAIN_PGC_0 = `0x30` | 去条件（两模式一致，之后由 AE 覆盖） |

### 帧率对齐

```
1H  = 861 clk / 74.25 MHz = 11.596 us
VMAX = 3449 行  →  3449 × 11.596us = 40.0 ms  →  25.0 fps
FPGA VTC (RES_MODE=2, 4K25) = 2060 × 2864 @147.5MHz = 40.0 ms  →  25.0 fps   ✔ 对齐
```

同步修改：
* `system_top.v`：`cam_param.i_vmax` 4K 分支 `4503 → 3449`；`i_gain_default` 统一 `0x30`
* `mipi_webstream.py`：`CAM_VMAX_4K = 3449`、`CAM_T_LINE_US_4K = 11.60`

---

## 3. 同时回退的误改（V26）

`0x3000 STANDBY` 手册（P40）写的是：

```
0: Operating    1: Standby
```

`0x3002 XMSTA`：`1h = Master operation ready`，`0h = Master operation start`。

因此 **"先写 1（挂住）→ 改模式寄存器 → 最后写 0（启动）"** 才是正确顺序；
V26 把主表 0/2 号项改成 `0x00`（等于"运行时切模式再挂待机"）是**误读**，V27 已回退：

| 位置 | 值 |
|---|---|
| 主表 index 0（`0x3000`） | `0x01`（Standby） |
| 主表 index 2（`0x3002`） | `0x01`（ready） |
| 参数表 `REG_DATA_ST` 0/1（`0x3000`/`0x3002`） | `0x00`（Operating / start） |

整表顺序 `主表(0..200) → 参数表(0,1)` 天然就是 *standby → 改模式 → 运行*，**原本就是对的**。

---

## 4. 还保留的机制（V25/V26 引入，本次不动）

* `RES_MODE (0xE0)` 写入产生一拍 `res_chg` → 触发整条视频通路协同复位 + `S_full_reload`
  （让传感器重新走完整表）。
* D-PHY RX 复位改为"**等 `O_cfg_done` 上升沿 + 150 ms 余量**"释放，超时 1.2 s 兜底。
  （V27 下两模式速率相同，本不需要变速；但同一速率下的复位已被验证无害。）
* `RES_MODE` 复位初值仍为 `2'd2`（上电直接 4K25），便于本次直接验证 4K 表；
  验证通过后可改回 `2'd0`。

---

## 5. 验证方法

```
# 1) 看帧计数（0.0 fps 就是 RX 没锁上）
ssh afc03 "sh /root/check_live.sh"

# 2) 掉线后用同一速率档刷新恢复（写 RES_MODE 会重走整表 + 复位）
ssh afc03 "python3 /root/rk/deploy/fpga_cfg.py set RES_MODE 0"
```

判定标准：
* `FRAME_CNT` 稳定在 ~25 fps（4K25）或 ~60 fps（切回 1080p）连续 30 s 不归零；
* 画面无撕裂、无花屏；
* 曝光 / 增益 / EV 三项在新模式下仍有效（`verify_cam_final.py` 5/5 PASS）。

---

## 6. 备选路线（若 891 Mbps 档仍失败）

1. **`0x301C WINMODE = 4h` 窗口裁剪模式** + `PIX_HST/HWIDTH/VST/VWIDTH`
   （`0x3040..0x3047`）。可直接裁出 3840×2160，且 `PIX_HWIDTH` 必须是 24 的倍数、
   `VMAX ≥ PIX_VWIDTH/2 + 46`。这条路与"全像素读出"是两套不同的寄存器集。
2. **换 720 Mbps 档**（`SYS_MODE=9`，1H=1017）——但注意该档要求 INCK = 24 或 72 MHz，
   与本板 INCK 是否匹配需先确认。
3. **回退到 1080p + 数码放大**（放弃 4K）。

---

## 7. 变更文件清单

| 文件 | 改动 |
|---|---|
| `fpga/uisrc/03_ip/ui_imx415_cfg/ui_imx415_reg.v` | SYS_MODE=5；速率相关 18 项去条件；HMAX/VMAX 改 861/3449；`0x3029` 新增条件；回退 0/2 号项 |
| `fpga/uisrc/01_rtl/system_top.v` | `i_vmax` 4K `3449`；`i_gain_default` 统一 `0x30` |
| `rk/web/mipi_webstream.py` | `CAM_VMAX_4K=3449`、`CAM_T_LINE_US_4K=11.60` |
| `tools/pdf_imx415.py`、`tools/pdf_pages.py` | 数据手册文本提取 / 页面渲染工具（新增） |
