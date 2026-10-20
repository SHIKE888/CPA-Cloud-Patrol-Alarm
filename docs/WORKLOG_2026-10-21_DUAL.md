# WORKLOG 2026-10-21 —— 双路 CSI（cam0/J2 + cam1/J3）

> 版本 `0x4600`（commit `99216e2`，分支 `feature/dual-csi`）
> 基线 `release-0x450D`（cam0 单路最佳版）

---

## 1 结论速览

| 项目 | 状态 | 证据 |
|---|---|---|
| cam0（子卡 J2 / CSI 座）单独出图 | ✅ 已验证 | 用户上板确认 1080p 画面与颜色正常 |
| cam1（子卡 J3 / 原 DSI 座）单独出图 | ✅ 已验证 | `0xD7=0x50`、`0xD8=0x5F`、`in_frame=1`；抓图 1920x1080 mean 113 / std 27.5 |
| 运行中反复切源 | ✅ 已验证 | 3 轮 ×3 次共 9 次，cam1 每次重新对齐 |
| 真·双路并行 | ⏳ 待硬件 | 目前只有一颗 IMX415 模组 |

---

## 2 引脚：cam1 的真实来源

之前依据「手册 CSI 连接器表」和 `docs/AFC03双路IMX415竞赛方案 (1).md` 2.2 表推导的
cam1 引脚**全部是错的**。权威来源是子卡原理图 `docs/MLK_FMC_MIPI_250530.pdf`：

- `P01_CON` 页：FMC 引脚 ↔ `CSI_*` / `DSI_*` 网络的直连表
- `P03_MIPITX` 页：J3 40pin 脚号 ↔ 网络名

| 功能 | J3 pin | 网络 | FMC | FPGA |
|---|---|---|---|---|
| HS_CLK P/N | 18 / 17 | `DSI_HS_CKP/N` | CLK1_M2C | **E16 / F16** |
| HS_D0 P/N | 14 / 15 | `DSI_HS_D0P/N` | LA29 | **F18 / G18** |
| HS_D1 P/N | 20 / 19 | `DSI_HS_D1P/N` | LA31 | **K16 / K17** |
| HS_D2 P/N | 22 / 23 | `DSI_HS_D2P/N` | LA30 | **D17 / E17** |
| HS_D3 P/N | 27 / 28 | `DSI_HS_D3P/N` | LA33 | **J17 / J18** |
| MCLK | 8 | `DSI_CLK`（串 R91 22R） | LA28_P | **J13** |
| RSTn | 4 | `DSI_RSTN` | LA28_N | **K13** |
| SCCB SDA | 35 | `DSI_IIC_SDA` | LA32_P | **N11** |
| SCCB SCL | 38 | `DSI_IIC_SCL` | LA32_N | **N10** |
| VCC | 40 | VCC_3V3 | — | — |

LP 对（LP-free RX 不用）：LP_CK=LA22(A13/B13)、LP_D0=LA19(G14/G13)、
LP_D1=LA21(H14/J14)、LP_D2=LA25(D18/E18)、LP_D3=LA24(J15/K15)。

### 两个被推翻的旧结论

1. **`N11` 不是 MCLK，是 SCCB SDA。** ECN 里拆 R671 / 贴 R672 的目的就是**打通相机 I2C**：
   改之前 `LA32_P → R671(0R) → INT_ALM_1V8`，SDA 线被 1.8V 电源占死。
2. 手册里写的 cam1 HS 对 `LA22/LA25/LA29/LA31` 是错的 —— LA22/LA25 在子卡上接的是
   `DSI_LP_CKP/N` 和 `DSI_LP_D2P/N`。

---

## 3 RTL 实现

```
cam0 PAD ──► X_mipi_csi_rx   ──► S_hs_clk0 ─┐
                                            ├─ LUT mux ─► PH1_LOGIC_BUFG ─► S_hs_rx_clk
cam1 PAD ──► X_mipi_csi_rx1  ──► S_hs_clk1 ─┘                                  │
                                                                               │
   两路 AXIS ──► (S_rx_sel_rx ? rx1 : rx0) ──► ui_image_correction ◄───────────┘
```

- **必须是两个独立 `mipi_csi_rx` 实例**：TD 的 `SYN-8207` 要求 IDDR/IDELAY 直连 PAD，
  在原语和 PAD 之间插 mux 会直接报 "can't be mapped into PAD"（0x4510 踩过）。
- **时钟 mux 后必须显式过 `PH1_LOGIC_BUFG`**：否则 `S_ud_wclk` 落在普通布线网上，
  偏斜导致写侧丢拍 → 画面向上滚动（0x450E 踩过）。
- **换源复位窗 120ms**（`SRC_RST_CYCLES`）：让 `ui_image_correction` / ISP / 预处理的
  行列计数器重新对齐新源。
- cam1 有独立一套 `O_clk_24m_1`(J13, ODDR) / `O_clk_rst_1`(K13) / SCCB(N10/N11)，
  并复制了第二个 `ui_cfg_imx415`，**上电两颗同时配好** —— 换源时不用等 201 条表的写入。

### 寄存器

| 地址 | 含义 |
|---|---|
| `0xDB` bit0 | CSI 源：0=cam0（上电默认） 1=cam1 |
| `0xDA` | Bayer 相位（不变） |
| `0xA9/0xAA` | 版本号 = 0x4600 |

---

## 4 顺带修掉的潜伏 bug

`cfg_ctrl_top.v` 里 `bsel_s2` 的声明在 `assign o_bayer_sel = bsel_s2` **之后**，
Verilog 会把它隐式声明成 1 bit wire → `O_cfg_bayer_sel` 只剩 bit0
→ 0xDA 的 GRBG(1)/GBRG(2)/BGGR(3) 实际全部塌成 bit0（只有 RGGB=0 是对的）。
TD 只报一条 `HDL-7225` 警告，很容易漏掉。已把声明上提。

---

## 5 仿真

```
cd fpga/sim
.\run_dual.ps1 all
```

| TB | 内容 | 结果 |
|---|---|---|
| `tb_dual_src` | 5 场景：只 cam0 / 双路跑选 cam0 / 只 cam1 / 双路跑选 cam1 / 运行中切回 | PASS |
| `tb_reg_db` | 0xDB 默认 0、写 1、写 0xFF 只取 bit0、0xDA 不串、版本 0x4600 | PASS |
| `tb_csi_full` | LP-free RX 整链回归（原有） | PASS |

`tb_dual_src` 每个场景核对 7 项：输出拍数、`tlast`、`tuser`、cam0 数据指纹计数、
cam1 数据指纹计数、其他值数（必为 0）、`O_line_groups`。B/D 两个场景专门证明
**未选中的那一路数据零泄漏** —— 这正是 0x4511 出鬼影时 `0xD4` 从 610 涨到 738
的最可能原因（两路输出在总线上被混在一起）。

---

## 6 上板实测数据（2026-10-21）

```
只插 cam1 到 J3，0xDB=1：
  0xD7 = 0x50   manual_mode=1, tap=16        （与 cam0 在 0x450D 时完全一致）
  0xD8 = 0x5F   autodone=1,   best_len=31
  0xD6 = 0xa4   in_frame=1, word_align=1, byte_align=0x4
  0xD4/D5 = 487 每行组数（cam0 是 486，差 1）
  0xD0/D1 = 197 → 254 → 310   SCCB 写次数递增 = 201 条表 + AE 参数在写

抓图 1920x1080：mean 113 / std 27.5，相邻行亮度差 mean 0.153（无撕裂）
连抓两帧 absdiff mean 1.809 → 画面是活的
```

cam0（J2 空着）读 `0xD6=0 / 0xD7=0x20 / 0xD8=0`，符合"没有摄像头"的预期。

---

## 7 已知问题

### 7.1 调试总线在"选到空源"时会骗人（待修）

`S_rx_sel_rx` 的同步器挂在 `S_hs_rx_clk` 上。切到一个**没有摄像头**的源时，
时钟 mux 切到了空时钟 → 同步器停摆 → 选源位卡在上一个值 → `0xDB=0` 时
`0xD6/D7/D8` 仍然显示 cam1 的数据。

数据通路本身是对的（cam1 每次都能切回来），但**诊断信息不可信**，会误导排障。

修法：`S_dbg_*_sel` 改用 25MHz 域的 `S_rx_sel` 直接选；只有 AXIS 数据 mux
继续用 rx 域同步后的 `S_rx_sel_rx`。

### 7.2 cam1 画面最右一列发红

中性灰场景下最右一列偏红，其余区域正常。配合 `0xD4/D5=487`（cam0 = 486）看，
像是行尾多 1 组的水平偏移。等第二颗模组到位、双路并排对比后再处理。

---

## 8 板上工具

| 脚本 | 用途 |
|---|---|
| `tools/board_dual_diag.sh` | 依次测 cam0 / cam1 / 切回，每个源先写 0xE0 重新对齐 |
| `tools/board_src_toggle.sh` | 反复写 0xDB 的切源压力测试 |
| `tools/board_snap_stat.py` | 抓 9012 快照并打印尺寸/均值/标准差/行差 |
| `tools/board_snap_live.py` | 连抓两帧做差，判断画面是不是冻结的 |

用法：`scp tools/board_*.{sh,py} afc03:/root/` 然后
`ssh afc03 'sh /root/board_dual_diag.sh'`。

---

## 9 下一步

1. 修 §7.1 的调试总线问题（小改动，与 0xDC 双路状态寄存器一起做）
   - `0xDC` 建议打包：cam0/cam1 各自的 `in_frame`、`autodone`、HS 时钟检测位
   - 这样双路都在时**不用切源**就能同时看到两路状态
2. 第二颗 IMX415 模组到位后，验证真双路并行
3. 处理 §7.2 的右边缘偏红
