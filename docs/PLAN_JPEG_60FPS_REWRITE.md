# JPEG 硬指标达成路线（双 1080p60 / 4K30 · 有损+无损+可变码率）

日期：2026-10-27 · 分支 `feature/dual-front-stitch`

> 本文只写**实测数字**和**由数字推出的结论**。所有数字都有出处（仿真台 / TD 时序报告 /
> 布局报告），没有推算的条目会明确标注。

---

## 1. 目标与现状的差距

| 项 | 数值 | 出处 |
|---|---|---|
| 指标要求吞吐 | **248.8 Mpx/s** | 双 1080p60 = 2×124.4；4K30 = 8.29M×30 = 248.8（两者相同） |
| 编码器有损代价 | **150.0 clk/MCU** | `fpga/sim/run_jpeg_thru.ps1 0`（2 帧平均，MCU=16×8=128px） |
| 编码器无损代价 | **320.2 clk/MCU** | `run_jpeg_thru.ps1 1` |
| 编码器可达 fmax | **45.061 MHz** | `phy_1/final_timing.rpt`：`clkc[1]` 组 Min Period 22.192ns |
| 时序违例 | WNS −15.413ns，2591/22976 端点 | 同上（147.5MHz 约束下） |
| 最差路径 | `X_jpeg_qt` 异步读 → `X_jpeg/u_quant` 量化乘加 = 21.9ns | 同上 |
| 当前实际吞吐 | 0.853 px/clk × 45MHz = **38.4 Mpx/s** | 128/150 × 45 |
| 等价帧率 | 1080p **18.5fps** / 4K **4.6fps** | 38.4 / 2.0736 / 8.2944 |
| **差距** | **6.5×** | 248.8 / 38.4 |

> ⚠ 之前"60fps 上限"的说法只按 150 clk/MCU @150MHz 算，**没算 fmax**，这里更正。

## 2. 资源墙：为什么不能简单堆并行

`phy_1/fpga_prj_phy.area`（0x470A 版，层次求和）：

| 实例 | DSP | 说明 |
|---|---|---|
| **top** | **234 / 240** | 总量 |
| u_preproc (preproc_top) | 110 | 其中 u_basic 82、u_edge 16、u_win 12 |
| X_ui_isp_top | 48 | ISP 基础链路 |
| **X_jpeg** | **48** | u_dct 32 + u_quant 16 |
| X_ui_Saturation_adj | 28 | |
| u_rgb2yuv_quad | 20 | |
| Contrast / AWB / preproc_post | 12 / 8 / 8 | |

**非 JPEG 部分已占 186 个 DSP，只剩 54 个。** 一个 JPEG 引擎要 48 个 ⇒
**现有功能集下只能放 1 个编码器实例**，并行 2/4 路立即超预算。

## 3. 三条可能的路（只有一条不需要删功能）

| 方案 | 吞吐 | 需 DSP | 判断 |
|---|---|---|---|
| A. 单引擎 @150MHz + clk/MCU 150→77 | 0.853×150 = 128 Mpx/s… **需 2 块并行才够** | 48 | 见下 |
| B. 2 引擎 @147.5MHz | 2×0.853×147.5 = **251 Mpx/s** ✅ | 96 | 需再腾 42 个 DSP |
| C. 4 引擎 @75MHz | 4×0.853×75 = **256 Mpx/s** ✅ | 192 | 不可能 |

> 方案 A 单引擎在 150MHz 下只有 128 Mpx/s，**必须**同时把 clk/MCU 从 150 压到 ≤77
> （即 2 个 block 同时在飞），才等于 249 Mpx/s。

**结论：主攻 A（纯流水线化，不动 DSP）**；B 作为后续选项，前提是先砍掉/简化
`u_preproc`（110 DSP）里的非必需算子腾出 ≥42 个 DSP。

## 4. 分阶段计划（每阶段都必须"仿真字节级一致"才算过）

| 阶段 | 内容 | 目标 | 验收 |
|---|---|---|---|
| **S0** ✅ | 仿真台修好并与生产接法一致（`O_rd_data_a_asyn`） | — | 3 个尺寸 `IDENTICAL`（见 §5） |
| **S1** | 量化通路拆流水：`jpeg_qtable_ram` 异步读改成"预先算好 inv_q + 寄存器输出"；`jpeg_quant_zz` 的 乘→加→移位 拆 2 级 | fmax 45→**90MHz** | `final_timing.rpt` clkc[1] WNS ≥ 0；`run_jpeg_sim.ps1` 全绿 |
| **S2** | DCT/熵编码重叠：`pend` 从 2 块扩到 3~4 块，DCT 与 huffman 真正并行 | clk/MCU 150 → **≤100** | `run_jpeg_thru.ps1 0` |
| **S3** | 深层流水 → fmax **150MHz**，clk/MCU ≤77 | **≈249 Mpx/s（有损）** | 时序 + `run_jpeg_thru.ps1 0` |
| **S4** | 无损同步流水化（现 320 clk/MCU，是 2.1×） | 无损也到 249 Mpx/s | `run_jpeg_thru.ps1 1` |
| **S5** | 可变码率闭环：`0x02~0x04` 目标字节 + `0x05` RC 使能，逐帧读回实际字节数调 Q | 目标码率误差 <±10% | 新增 `tb_jpeg_rc.v`：给目标 120KB/240KB/480KB 各跑 8 帧 |
| **S6** | 4K/双目的行缓冲：`y_mem` 8192×64 映射 ERAM 失败（0x4709 时期 slice 88.9%） | 4K30 与 双1080p60 都能跑 | 综合后 ERAM ≤ 200/272、slice ≤ 78% |

> S6 必须在 S3 之前落地一次，否则 4K 通路根本装不下 —— 两条指标都要 3840 宽度。

## 5. 仿真现状（S0 完成）

```
tools\run_jpeg_sim.ps1 -Sizes @("64x16","320x40","1920x48")
    64x16        IDENTICAL 862 bytes
    320x40       IDENTICAL 3797 bytes
    1920x48      IDENTICAL 23580 bytes
    ALL PASS (byte-identical to jpeg_ref.py)
```

**本轮修掉的仿真台缺陷（会误导所有结论，必须记）**：
`tb_jpeg_e2e.v` / `tb_jpeg_thru.v` 之前把 qtable 接在 `O_rd_data_a`（寄存器口，滞后 1 拍），
而生产代码 `system_top` 用的是 `O_rd_data_a_asyn`。结果 DQT 头第一个 Q 值被复制成两个字节，
被误判成"编码器 DQT 生成有 bug"。**仿真台必须与生产接法逐根线对齐。**

已知未绿：`tb_jpeg_csi2_e2e.v`（`csi2_frame_tx_var` 全链路）—— 现在 `FS=18/FE=14`
但只有 520 字节 payload，帧边界发多了。这是 `csi2_frame_tx_var` 的行为问题，
S3 之后要连发送侧一起重做，届时重写该仿真台。

## 6. 不做的事（明确排掉，避免重复讨论）

- ❌ 不要再指望"提高 PLL 到 300MHz"——`clk/MCU` 不变的前提下只能到 256 Mpx/s，
  但 fmax 45MHz 是逻辑决定的，不是 PLL 决定的。
- ❌ 不要再尝试把编码器挂在 `S_pclkx1/S_dsi_hs_x2`（147.5/150MHz）上而不改逻辑：
  已实测 WNS −15.4ns，输出必然是错的。
- ❌ 不要在 DSP 用满的情况下加第 2 个编码器实例（会直接布不下）。
