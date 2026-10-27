# 双目同时采集 + 行乒乓 + 左右拼接（Stage 1 落地）与 60fps 门限核算

日期：2026-10-27
分支：`feature/dual-front-stitch`
本文件**只写已验证的事实**，推算的地方明确标注「推算」。

---

## 1. 本次落地了什么

新增（纯增量，未改动任何现有通路，默认 bit 流行为不变）：

| 文件 | 作用 |
|---|---|
| `fpga/uisrc/01_rtl/dual/dual_stitch.v` | 双目**同时**采集：每源一个跨时钟 FIFO（`fifo_32b_async_2`，40bit），读侧按「先左半 HGRP 组、再右半 HGRP 组」拼一行 |
| `fpga/sim/tb_dual_stitch.v` | 定向仿真台（含掉一路 / 恢复 / 两路不同频） |
| `fpga/sim/run_dual_stitch.ps1` | 一键跑（oss-cad-suite 里的 iverilog） |

映射关系按用户要求：**左半幅 = cam1，右半幅 = cam0**（`SWAP=0`）。

关键不变量（这是本模块唯一真正难的地方）：**FIFO 里的 word 流必须严格「每行 HGRP 个」**，
否则左右会永久错一个 word。写侧用三条规则保证：
1. 一行内多于 HGRP 的组直接丢（传感器可能给 486 组，裁剪只留 480）；
2. 一行内不足 HGRP（tlast 提前）→ 补零到 HGRP；
3. FIFO 复位中/满导致整行写不进去 → **整行丢弃**（不能补零，否则会多吐一行黑的），
   只吞到 tlast 为止。

掉一路（没插模组 / RX 没锁）时：该源 FIFO 永远空 → 读侧超时判定 starved →
该半幅填黑、**整条流水线照另一路的节奏继续跑**。这样"切到没有时钟的源整条链死锁"
这个老问题从结构上就不存在了（不再需要时钟 mux）。

## 2. 仿真结果（可复现）

```
cd 08_csi2rk_mipi_imx415/fpga/sim ; .\run_dual_stitch.ps1
```

参数：`HGRP=16 / V_ACT=8 / FIFO_AW=11 / STARVE_MAX=300`，两路时钟 30.86ns(32.4MHz)
与 30.10ns(33.2MHz)，输出 13.56ns(73.75MHz)，故意不锁相。

实测输出（RESULT: **PASS**）：

```
=== Phase 1: dual simultaneous capture, 6 frames ===
  frames=6 lines=47 groups=1535 tuser=6 tlast=47 black(L/R)=16/0
=== Phase 2: cam1 stopped ===
  during stop: black L=864 R=0 starve_l=1
=== Phase 3: cam1 resumed ===
  steady state after resume: black L=0 R=0
 ovf L/R    = 1 / 1     (pad/drop events)
 starve L/R = 2 / 1     (recoveries)
RESULT: **PASS**
```

断言内容：
- 左半幅每一组的 tag 必须是 `0xA5`(cam1)、组序号必须是 `0..HGRP-1`（无丢组/无重复）；
- 右半幅 tags 必须是 `0x5A`(cam0)、组序号必须是 `0..HGRP-1`；
- `tlast` 只出现在每行最后一组，`tuser` 每帧只出现一次；
- cam1 停流后左半全 0、右半不受影响且输出不中断；恢复后稳态零填黑。

`ovf=1/1`、`black(L/R)=16/0`、Phase1 首行左右行号有偏差：这三件都是**上电首个 FIFO
内部复位窗（3 个 wr_clk）造成的一次性启动瞬态**，之后自愈（第 2 帧起严格对齐）。
仿真台因此在 Phase 1 与 Phase 3 的过渡窗口关闭「左右行配对」断言，稳态窗口开启。

## 3. 60fps 的可达性：把门限算清楚

### 3.1 前端（采集/拼接/ISP/写 DDR）——**可行**

| 量 | 值 | 依据 |
|---|---|---|
| 目标像素率 | 3840×1080×60 = **248.8 Mpx/s** | 算术 |
| 单源 4px/clk 需要的时钟 | 480 组 / 14.8us ≈ **32.4MHz** | IMX415 1080p60 恢复时钟实测≈32.4MHz |
| 拼接读侧时钟 | 2×(480+2) 拍/行 = 964 拍 → **≥62.2MHz**；规划 73.75MHz（pclkx1/2） | 本文档 §1 |
| 73.75MHz 下读侧行耗时 | 964/73.75M = **13.07us** < 14.8us（余量 12%） | 算术 |
| DDR 写+读 | 498+498 = **996MB/s**（4K25 已验证 828MB/s） | 推算，需板上实测 |

→ 采集→拼接→ISP→写DDR这一段，按 73.75MHz 设计是可以吃下 60fps 的；
   剩下的风险是 **ISP/preproc 在 73.75MHz 下的时序收敛**（4K25 时是 51.8MHz，+42%）。

### 3.2 硬件 JPEG —— **当前设计做不到 60fps，这是硬数字**

| 量 | 值 | 依据 |
|---|---|---|
| MCU 数/帧（4:2:2, 16×8） | 240 × 135 = **32400 MCU** | 算术 |
| 60fps 需要 | 32400 × 60 = **1.944 M MCU/s** | 算术 |
| 编码器实测吞吐 | **150.0 clk/MCU** | `tb_jpeg_thru`（`run_jpeg_thru.ps1`，已复核） |
| ⇒ 需要时钟 | 150 × 1.944M = **291.6MHz** | 算术 |
| 编码器现状 | 挂 `S_hs_rx_clk`≈31.25MHz（`jpeg_encoder_top.v`/`system_top.v`） | 代码 |
| 编码器 fmax | **45.06MHz**（最差路径 quant 异步读→量化乘加 21.9ns；147.5MHz 下 WNS −15.413ns） | `0x470B` 时序报告 |
| 器件余量 | slices 43860/64320 (68.19%)、ERAM 164/272 (60.29%)、**DSP 234/240 (97.50%)** | `fpga/fpga_prj_Runs/phy_1/run.log`（2026-10-27 16:40 构建） |

结论（都是上面几行的直接推论，不是感觉）：
1. **"再放一个编码器并行"不成立**：DSP 只剩 6 个，一个 8×8 DCT 都要几十个乘法器。
2. **"单编码器跑到 291MHz"不成立**：现在 fmax 45MHz，差的不是一点，是 6.5 倍；
   最差路径就是量化那一段（量表异步读 + 乘加），必须拆流水才能上 100MHz 量级。
3. 因此 **3840×1080@60 + FPGA 硬件 JPEG，在本器件当前实现下不可能同时达成**。

### 3.3 能达成 60fps 的三条路（按代价排序，都没验证过）

1. **提 fmax + 熵编码双符号/拍**（不动 DSP）
   - 量化桶：量表改同步读 + 乘加拆两级流水 → 目标 120~150MHz（需综合验证）。
   - 熵编码：1 符号/拍 → 2 符号/拍（Huffman 双查表 + 双 barrel shift），
     把 150 clk/MCU 压到 ~75 clk/MCU。
   - 75 clk/MCU @150MHz ⇒ 256 Mpx/s ⇒ **刚好够 248.8**（余量 2.9%，很薄）。
2. **DRI 重启间隔 + 多段并行编码**（真正的正交提速）
   - 把一行切成 N 段，每段一个独立 restart interval（DC 预测清零），
     各段由独立引擎编码后按 RST0..7 拼接成一个合法 JPEG，浏览器/解码器完全支持。
   - 但 N=2 就需要 2 套 DCT/行缓冲 —— **当前 DSP 不允许**，必须先砍掉/换掉别处的乘法器
     （V47.13 已经砍了部分预处理，需重新综合看真实余量）。
3. **退一档指标**：3840×1080@30（编码器需 145.8MHz，配合路线 1 的 fmax 提升即可），
   或者双路各自 1080p30 + 前端 60fps 采集（拼接流仍是 60fps，编码器 30fps 出图）。

**在拿到「fmax 实测」与「DSP 真实余量」之前，任何关于 60fps+JPEG 的承诺都是猜的。**
这两个数都只能靠 TD 综合得到，仿真给不出。

## 4. 接入 system_top 还缺什么（Stage 2~5，按顺序做，每步可回退）

1. **时钟**：`S_st_clk = S_pclkx1 / 2`（Toggle FF + `PH1_LOGIC_BUFG`），
   把 `ui_isp_top` / `preproc_top` / `preproc_post` / `rgb_to_yuv422_quad` 的时钟
   从 `S_hs_rx_clk` 换成 `S_st_clk`；`dual_stitch` 的 `o_clk` 也用它。
   ⚠ 先只换时钟、`dual_stitch` 旁路跑单目，确认 73.75MHz 下 **SWNS ≥ 0** 再往下走。
2. **宽度**：`S_h_active` 在拼接模式下取 3840、`S_v_active` 取 1080；
   `S_w_beats=960`（64b/4px 写）、`S_r_beats=1920`（32b/2px 读）—— 这两组 4K 模式已经在用。
3. **VTC**：新增 `RES_MODE=3`（拼接 3840×1080，`h_frame=2652/v_frame=1125`，
   帧率 49.4fps 先打通）与 `=4`（`h_frame=2200` → 59.6fps）。
   ⚠ `GAP_LINE=200` 是板上验证过的基线，不许动。
4. **删时钟 mux**：`S_hs_rx_clk_mux` / `X_bufg_rx_clk` / `S_clk_sel_r` 全部去掉，
   `0xDB[0]` 降级为"网页看哪半"；两路 RX 的 `m_axis_video_aclk` 各自接自己的
   `S_hs_clk0/1`，`dual_stitch` 是唯一的跨时钟点。
5. **Bayer 相位**：两颗 IMX415 同型号同配置 → 拼接后左右半幅的 Bayer 相位一致
   （都用 `0xDA` 选），这点必须板上抓图确认，不能只看代码。

## 5. 板上必须先测的三件事

1. 73.75MHz 下 ISP/preproc 的综合 WNS（当前整设计 Setup WNS **−6.503ns / Hold −2.876ns**
   已经是负的，先要搞清楚这 −6.5ns 落在哪个时钟域，否则提速毫无意义）。
2. DDR 读写合计 ~996MB/s 是否稳定（4K25 的 828MB/s 是唯一参考点）。
3. 拼接后左右半幅的 Bayer 相位与左右顺序（把 cam1 遮住，确认左边变黑）。
