# 双目同时采集接入 system_top（2026-10-28）

对应作品要求：**1080p@60FPS 双目图像采集** + 预处理（高斯/直方图均衡/灰度/Sobel/阈值/形态学）。

## 1. 改了什么（全部在 `fpga/uisrc/01_rtl/system_top.v`）

| # | 改动 | 说明 |
|---|---|---|
| 1 | **删掉 RX 时钟 mux** | 原来 `S_hs_rx_clk = mux(S_hs_clk0, S_hs_clk1)`，同一时刻只有一路有时钟 ⇒ 不可能同时采。现在两路 RX 的 `m_axis_video_aclk` 各接自己的 `S_hs_clk0/1`，两路 crop 也各在自己的恢复时钟域 |
| 2 | **新增 `S_st_clk = pclkx1/2 = 73.75MHz`** | 拼接/下游像素域；`S_hs_rx_clk` 这个名字保留并指向它，所以 ISP/preproc/dbuf/VTC 一行没改 |
| 3 | **新增 `S_enc_clk = pclkx1/4 = 36.875MHz`** | JPEG 编码器专用（旧 fmax 45MHz，绝不能跟着像素域跑到 73.75MHz） |
| 4 | **`dual_frame_sched` → `dual_stitch`** | 逐帧交替（各 30fps）→ 每行同时进 FIFO、左右拼接（左 cam1 / 右 cam0） |
| 5 | 图像几何固定为 **3840×1080** | `S_h_active=3840`、`S_v_active=1080`、`S_w_beats=960`(64b)、`S_r_beats=1920`(32b)；新增 `S_cam_h=1920` 给两路 crop 用 |
| 6 | **4K 废弃** | `S_is_4k` 恒 0；`S_vtc_v_frame` 固定 1125（59.6fps）；不再响应 `RES_MODE=1/2` |
| 7 | **编码器只吃左半幅** | `jpeg_encoder_top` 是 `#(.W(1920))`，行缓冲按 1920 组织；拼接后一行 3840px 会让它"每帧 (W/2)*H 个 word"的定长消费算错 ⇒ 数行内组号，只放前 480 组/行给编码器 |

工程文件列表 `fpga/fpga_prj.al` 已加入 `dual/dual_stitch.v`（CompileOrder 200）与
`jpeg/jpeg_recip_pipe.v`（201），并核对 `<File>` 标签 105 → 107 配对正常。

## 2. 现在这条链

```
cam1 ─ RX1 @S_hs_clk1 ─ crop(cam_h=1920) ─┐
                                          ├─ dual_stitch @73.75MHz ─ 3840×1080@60 40bit
cam0 ─ RX0 @S_hs_clk0 ─ crop(cam_h=1920) ─┘
      → ui_isp_top → preproc_top(高斯/HE/灰度/Sobel/阈值/形态学) → preproc_post
      → rgb_to_yuv422_quad → ui_dbuf(写 960 beat/行) → ui_vtc(读 1920 beat/行)
      → csi2_pack → csi2_frame_tx(DT=0x1E) → D-PHY → RK3576
```

- `0x0B[0]=0`（默认）：RK 收到 **3840×1080@60 NV16**，左半 = cam1、右半 = cam0。
- `0x0B[0]=1`：RK 收到 **左目 1920×1080 JPEG**（编码器 36.875MHz ⇒ ~15fps，仅能力验证）。

## 3. 已验证 / 未验证

已验证（离线）：
- `run_dual_stitch.ps1`：双路同时采集 + 行乒乓 + 左右拼接 + 掉一路填黑，**PASS**。
- `python tools\check_syscon.py`：声明顺序/多驱动/例化端口全部通过。
- `iverilog` 解析 `system_top.v`：只有"Unknown module type"（厂商 IP 不在本地），**无语法错误**。
- `run_jpeg_recip.ps1` / `run_jpeg_thru.ps1` / 端到端逐字节 862B IDENTICAL。

必须上板验证（我无法在这里做）：
1. **73.75MHz 下 ISP/preproc/dbuf 的时序收敛**（4K25 时是 51.8MHz，+42%）。
2. 左右半幅顺序与 Bayer 相位：遮住 cam1 → 左半应变黑；两颗同型号应同相位（`0xDA`）。
3. DDR 读写合计 ≈ 996MB/s 是否稳定。
4. rkcif 对 3840×1080@59.6 的接受度（场消隐 671µs）。

## 4. 还没达标的指标（有硬数字，不是判断）

- **JPEG 60fps**：实测 150 clk/MCU ⇒ 3840×1080@60 需 **291.6MHz**；单目一个引擎需 **145.8MHz**，
  当前编码器 fmax 45MHz（量化除法器已换成 22 级流水长除法，但新 fmax 未知）。
  可行路线只有两条，都需要先解决 DSP：DSP 已 234/240。
  ① 2 引擎 ×146MHz（要再腾 48 DSP，只能把 `preproc_basic` 的 82 DSP 移位加法化，功能不删）；
  ② 4 引擎 ×73.75MHz（要 192 DSP，不可行）。
- **无损 60fps**：320 clk/MCU ⇒ 622MHz ⇒ 必须 4~8 段并行（无损无 DSP）；且现有无损路径有
  "第二帧不再出帧"的既存 bug。
- **可变码率**：`jpeg_qtable_ram` 的写口被接成 `I_wr_en(1'b0)`（只有固定表），要开写口 + 寄存器下发。
- **删 NV16 通路**：`ui_ddr+ui_dbuf+ui_vtc+csi2_pack+csi2_frame_tx ≈ 5.2k LUT + 34 ERAM`
  可在 JPEG 达标后删除；现在保留是因为 JPEG 还喂不了 3840×1080@60。
