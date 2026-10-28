# V51（0x5100）：移除 NV16，MIPI 只发 JPEG

日期：2026-10-28
代码版本：`CFG_VER = 0x5100`（I2C 读 0xA9/0xAA → 低字节 0x00 / 高字节 0x51）

---

## 1. 为什么要删 NV16

不是"清理代码"，是**物理上不可能**。

| 项 | 数值 |
|---|---|
| 输出宽（双目拼接） | 3840 × 1080 |
| YUV422 一行负载 | 7680 B = 1920 个 4B word |
| byte_clk | 125 MHz（VCO 1000MHz / 8） |
| 每行 TX 时间 | (1920 + 200 GAP) / 125M = **16.96 µs** |
| VTC 行预算 | 2200 / 147.514M = **14.91 µs** |
| **超支** | **2.05 µs（13.7%）** |
| 链路利用率 | 3840×1080×60×2B = **498 MB/s** / 4lane×1000Mbps = **500 MB/s** → **99.6%** |

两条各自都足以判死。所以：

- NV16 的帧率上限是 **52.3 fps**，V50b 用内置 TPG 实测 **50.4 fps**，完全对得上；
- VTC 不知道"TX 排不下"，照样按时拉下一行 → packer 输出 FIFO 被抢空 →
  `s_tvalid` 掉一拍 → `hs_en` 撤 → 包被截断 → **CRC 满屏 → 1.6 fps**。

历史基线说明（回答"NV16 以前能跑满 60 帧"）：

| 时间 | 提交 | byte_clk | 输出行宽 | 60fps? |
|---|---|---|---|---|
| 2026-10-15 | `c5a114e` V21 | 150 MHz | — | 提频后花屏 |
| 2026-10-15 | `e9c6918` V22 | **125 MHz** | — | 回退（600MHz hs 时序不收敛） |
| 2026-10-18 | `fcd4cc5` V43 | 125 MHz | **1920（单目）** | ✅ 每行 1160 clk = 9.28µs，余量 37.8% |
| 2026-10-28 | `8f09d58` 双目 | 125 MHz | **3840（拼接）** | ❌ 行宽翻倍 → 超支 |

`CLKC0_DIV(48)`（150 MHz）在整个 git 历史里**只存在于 V21 一个提交**。
所以"60fps 基线"是 **1920×1080 单目**；变成 3840 宽双目之后就不可能了。

---

## 2. 删掉了什么（FPGA）

| 删除项 | 说明 |
|---|---|
| `csi2_pack_yuv422_stream` 例化 | NV16 字节打包 + CDC（源文件保留，不例化不综合） |
| `csi2_frame_tx` 例化（定长） | 每行一个定长长包，GAP_LINE=200 |
| `csi2_test_src` 例化 | 内置测试图案，只能从定长 TX 出去 |
| 读侧帧标记注入 `S_mark_*` | 往 NV16 的 Y 平面塞 `A5 5A src FF`，对 JPEG 是污染 |
| `S_dsi_R_tdata32` / `S_dsi_pack_tready` 声明 | 随通路一起删 |
| `TX_SRC_SEL` / `JPEG_TEST_SRC` | 三选一 mux |
| `S_hs_en` / `S_hs_data` / `S_hs_last` | 定长 TX 的输出 |

## 3. 留下的唯一通路

```
IMX415 → mipi_csi_rx → ui_image_correction → dual_stitch → ui_isp_top
       → preproc_top → preproc_post → rgb_to_yuv422_quad
       → ui_dbuf (32b/2px) → ui_vtc 节拍读出
       → yuv32_to_quad (32b@147.5M → 64b/4px@70.24M)
       → jpeg_enc_if ×4 → jpeg_encoder_top ×4（16×8 MCU，DRI 60）
       → jpeg_seg_merge4 → jpeg_byte_bridge
       → csi2_frame_tx_var（变长，PKT_BYTES=1024）
       → mipi_dphy_tx_wrapper → RK3576 CSI3
```

## 4. 寄存器语义变化

| 位 | 原 | 现 |
|---|---|---|
| `0x0B[0]` JPG_TX | 0=NV16 / 1=JPEG | **锁死 1**（硬件端 `localparam`） |
| `0x0B[1]` DT18 | 0=DT0x1E / 1=DT0x18 | **锁死 0** |
| `0x0B[2]` JPAD | 默认 1（补零到 8,294,400B） | **默认 0（变长帧）** |

### ⚠ DT 为什么仍然是 0x1E 而不是 JPEG 标准值 0x18

这是**传输容器**，不是数据格式：

- rkcif **完全没有** JPEG 支持 —— `CIF_FMT_TYPE` 只有 YUV/RAW，
  `V4L2_PIX_FMT_JPEG/MJPEG` 在 `drivers/media/platform/rockchip` 零命中，
  `capture.c` 里自己写着 `JPEG, TODO`；
- 驱动只能上报 `MEDIA_BUS_FMT_YUYV8_2X8` → CSI-RX 按 DT=0x1E 收；
- **板上实测（0x470A）**：DT=0x18 直接被拒收，报 `MIPI_CSI2 err id + crc/ecc`。

所以 JPEG 码流当"普通像素"塞进 YUV422 容器，RK 侧不解析，
应用层从 vb2 buffer 里扫 `FF D8 … FF D9` 直接推流（零解码零重编码）。
详见 `docs/VARLEN_CSI2_JPEG_2026-10-28.md`。

## 5. `csi2_frame_tx_var` 的 enable 改了

原来接 `0x0B[0]`（NV16 时要置 0 才关掉 JPEG），现在接 `S_dsi_en_int`
（RK 的 stream-on 信号）。

理由：`enable=0` 会清空乒乓缓冲。如果 D-PHY 还在复位时就把整包塞进去，
RK 开流后的第一帧是残帧。`!enable` 分支里 `d_rd <= d_wr` 保证 `pend_v` 恒 0、
`s_tready` 恒 1，所以关闭期间桥不会死锁（这是 2026-10-28 修过的坑）。

---

## 6. 未改动 / 需上板确认

1. **RK 驱动不动**：继续上报 `MEDIA_BUS_FMT_YUYV8_2X8` / 1920×1080。
   因为上面说的原因，改成 `JPEG_1X8` 反而会直接收不到帧。
2. **`rk/web/mipi_webstream.py` 不动**：`--fourcc NV16` 是 V4L2 的
   *容器* 格式，由驱动决定；实际内容是 JPEG，`_jpeg_in_frame()` 已经会
   检测 `FF D8` 并走 `_publish_direct()`。
3. **变长帧依赖内核补丁** `0001-cif-allow-variable-length-csi2-frames.patch`
   （commit `76ba3d1`，把 `CSI_SIZE_ERR` 从 `CIF_REG_MIPI_LVDS_INTEN` 抠掉）。
   **上板前必须确认烧的 kernel 里有这个补丁**，否则短帧会被当成错误整帧丢弃。
4. `ui_vtc` 保留 —— 它仍是 dbuf 读侧的节拍源（`I_R_en = S_vtc_vs`）。
   `O_vtc_de_valid` 现在没有负载了，属正常。
5. `csi2_pack_yuv422_stream.v` / `csi2_test_src.v` 文件保留在工程里
   （不例化 → 综合时被裁掉），以后要压链路可以给 TPG 加一层 32→8 字节化。

---

## 7. 上板验证清单

```bash
# 1. 版本号：应为 0x5100（低 0x00 / 高 0x51）
i2cget -y 9 0x40 0xA9 ; i2cget -y 9 0x40 0xAA

# 2. 0x0B 回读：bit0=1, bit1=0, bit2=0  → 0x01
i2cget -y 9 0x40 0x0B

# 3. 编码器是否在出帧（0xA0~A2 帧字节数应非 0）
i2cget -y 9 0x40 0xA0 ; i2cget -y 9 0x40 0xA1 ; i2cget -y 9 0x40 0xA2

# 4. 链路健康：MIPI_CSI2 错误应为 0
dmesg | grep -i csi2 | tail -20

# 5. 抓一帧看是否真是 JPEG
curl -s http://127.0.0.1:9012/api/snapshot -o /tmp/s.jpg && file /tmp/s.jpg
```

判定：
- `0xA0~A2` 恒 0 → 编码器没出帧，问题在编码器/源，不在链路；
- `0xA0~A2` 有值但 RK 侧 `frame_id` 不涨 → 变长帧补丁没生效或链路问题；
- `frame_id` 涨但画面不动 → 网页/解码环节。
