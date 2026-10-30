# 根因定位：JPEG 字节流用 YUV422 的 DT 发送，RK 侧必然花屏

日期：2026-10-30
板上版本：`CFG_VER = 0x5402`
现象：左目全绿花屏、右目全黑、web 报 cam1 不在线

---

## 一、现象量化

| 观测 | 数值 |
|---|---|
| `v4l2-ctl --get-fmt-video` | 1920×1080 `NV16` |
| `/snapshot` 实际内容 | 大片纯绿 `YUV(128, 0, 0)` + 局部彩色噪声 + 水平细线 |
| 纯绿区域占比 | 左半幅约 3/4，右半幅全部 |
| `0xA3~0xA6` | `A6=0x80` → `encif_full[3]=1`（引擎3输入 FIFO 满） |
| `0xEF` | `0x34` → `jb_r=1, jv_rx_ready=0, jb_v=0` |
| `0xE4` | `0x96`（桥内有 150 字节） |

**纯绿 = YUV(128,0,0)**，即亮度中性、色度为零 —— JPEG 码流里的字节被当成 YUV 像素解释后的统计结果。

---

## 二、根因（三层证据）

### 证据 1：FPGA 发的不是 YUV，是 JPEG 字节流，却标了 YUV 的 DT

```verilog
// system_top.v
localparam S_jpeg_dt18 = 1'b0;        // ← 硬编码常量，DT 固定 = 0x1E (YUV422)
```

```verilog
// system_top.v 第 2451 行
// ★ V51: 移除 NV16 —— o_jpeg_tx / o_jpeg_dt18 不再使用 (MIPI 恒定发 JPEG)
```

板上读回 `0x0B = 0x01`：`jpg_tx=1`（JPEG 发送已开）、`jpg_dt18=0`（DT 不是 0x18）。
**注意 `0x0B[1]` 虽然可写，但在 RTL 里 `S_jpeg_dt18` 是常量，写它不影响行为。**

### 证据 2：RK 驱动只认 YUYV8_2X8，不认识 JPEG

```c
// rk/driver/milianke_mipi.c — 三处全是硬编码
177:  code->code = MEDIA_BUS_FMT_YUYV8_2X8;   // enum_mbus_code
207:  fmt->format.code = MEDIA_BUS_FMT_YUYV8_2X8;  // get_fmt
328:  fie->code = MEDIA_BUS_FMT_YUYV8_2X8;   // s_stream 配置
```

```
// 板上实测
/dev/video22 支持: NV16 NV61 NV12 NV21 YUYV YVYU UYVY VYUY
最大尺寸: 1920x1080
→ 没有 MJPEG，没有 3840 宽
```

所以 rkcif 一定按 **DT=0x1E + YUYV8_2X8** 解析收到的字节。FPGA 送的是 JPEG 码流 → 必然花屏。

### 证据 3：补零长度与收端期望差 2 倍

```verilog
localparam [24:0] JPAD_BYTES = 25'd8_294_400;   // 3840*1080*2
// 注释: rkcif 的 DMA 按 w*h*bpp 往 DDR 写: 1920x1080 NV16 = 4,147,200 字节/帧
```

收端期望 `4,147,200`，FPGA 补到 `8,294,400` —— 差 2 倍，帧边界必然错位。
而且 `0x0B[2] jpg_pad = 0`，**补零功能本身是关闭的**，JPEG 帧（约 275KB）后直接跟下一帧。

---

## 三、为什么之前会误判「JPEG 链路已通」

`docs` 与提交记录里的「3840×1080 JPEG frames emitted, 275746 B, `verify_jpeg.py` PASS」
来自 **iverilog 仿真输出**（`fpga/sim/*.jpg`、`tb_wd_full`、`tb_pre2jpeg`），
**不是板上实测**。板上从未真正解码出一帧 JPEG。

仿真验证的是「FPGA 内部能把像素编码成合法 JPEG」，这部分是对的；
缺的是「RK 侧能否接收」这一环，而这一环从来没有被验证过。

---

## 四、带宽算术：为什么必须压缩

MIPI 配置：`link_freq = 500MHz` → 单 lane `1000Mbps`，4 lane，
扣 8b/10b 编码后有效带宽 = `4 × 1000 × 0.8 / 8 = 400 MB/s`。

| 方案 | 字节/秒 | 结论 |
|---|---|---|
| 1920×1080@60 YUV422 | 248.8 MB/s | ✅ 可行 |
| **3840×1080@60 YUV422** | **497.7 MB/s** | ❌ **超上限 24%** |
| 3840×1080@30 YUV422 | 248.8 MB/s | ✅ 可行（帧率减半） |
| 3840×1080@60 JPEG (Q=88) | ≈ 60~90 MB/s | ✅ 富余 |

**结论：双目拼接 3840×1080@60 的原始 YUV422 在物理上发不出去（除非提 MIPI 速率，
而历史记录表明 1200Mbps 下 FPGA 内部时序收敛不了，画面花屏，已回退）。
所以 JPEG 压缩不是可选项，是必需项。**

---

## 五、PCIe 备选路径已排除

`rk03/pcie.dtsi` 里 PCIe1 已配置为「Anlogic FPGA Endpoint (FPC 连接)」，`status = "okay"`。
但板上实测：

```
lspci            → 空
/sys/bus/pci/devices/ → 空
dmesg | grep pcie     → 无记录
```

FPGA 侧 PCIe EP 未实现，走这条路需要从零做 PCIe 硬核 + DMA + 驱动，不在当前范围。

---

## 六、可选的修复方向

### 方案 A：改 RK 驱动支持 MJPEG（保持 FPGA 不动）

- 改 `milianke_mipi.c`：`enum_mbus_code` / `get_fmt` / `s_stream` 增加
  `MEDIA_BUS_FMT_JPEG_1X8` 分支
- 改 `csi-imx415-2.dtsi` 对应配置
- 需要重编内核（`docs/VM_KERNEL_BUILD.md` 有环境）
- FPGA 侧把 `S_jpeg_dt18` 改成 `1'b1`（DT=0x18）
- **风险**：这颗内核的 rkcif 是否支持 `JPEG_1X8` → 必须先验证
- **收益**：唯一能同时满足「双目 + 1080p60 + 压缩传输」的方向，且符合作品方向

### 方案 B：FPGA 回 YUV422 直传（最快出图，但降规格）

- 恢复 `csi2_pack_yuv422_stream` 通路
- 带宽限制下只能选：
  - 1920×1080@60 单目（能看到清晰画面，但不是双目）
  - 3840×1080@30 双目（是双目，但只有 30fps）
- **收益**：验证采集/拼接/预处理全链路正确性，作为回归基线

### 推荐顺序

1. **先做 A 的可行性验证**（半天量级）：只改驱动加 `JPEG_1X8`，编模块加载，
   看 `/dev/video22 --list-formats-ext` 是否出现 MJPEG。出现 → A 可行，继续。
2. 若 A 不可行 → 做 B 拿到「双目 30fps 或单目 60fps」的可用画面作为基线，
   再把压缩传输改走别的物理通道（PCIe / 网口）。

---

## 七、本轮新增的诊断手段（已提交，可用于后续）

| 地址 | 含义 |
|---|---|
| `0x0C~0x0F` | `rgb_to_yuv422_quad` 输入 pix0 = `{tog, in_b, in_g, in_r}` |
| `0xFC~0xFF` | `rgb_to_yuv422_quad` 输出 pair0 = `{out_cr, out_y1, out_cb, out_y0}` |

`CFG_VER = 0x5403`（`0xA9/0xAA` = `0x03 0x54`），`rk/deploy/diag_v54f.sh` 可一键读取。

这两个抽头用于区分「色度在 ISP 输出前就没了」还是「在 rgb2yuv 里算错」——
在方案 A 打通之后，仍需用它们确认色度一路正常。

---

## 八、cam1 `cfg_done=0` 的独立问题

```
cam0: {cfg_done: 1, ae_cnt: 17,  alive: true}
cam1: {cfg_done: 0, ae_cnt: 103, alive: false}
```

`RX_SEL = 1`（默认选 cam1）→ 显示的是那路未初始化成功的通道。
切到 `RX_SEL = 0`（cam0）后画面仍是纯绿，说明**主链路问题（DT 不匹配）在 cam1/cam0 之上**，
必须先解决 DT 问题，`cfg_done` 才有意义。二者不是同一个 bug。
