# 相对官方例程的改动清单

基线：`AFC03_IMX415_MIPI_RK(0531).zip`（已备份为 `fpga_reference_src.zip`）

原则：**不改动已验证的时序与数值**，只做参数化、可读性与部署便利性增强。

---

## 一、FPGA 端（`fpga/`）

### 1. `uisrc/01_rtl/system_top.v`

| 改动 | 说明 |
|------|------|
| 顶部注释 | 补充完整数据流说明、FPGA↔RK 必须一致的约束（分辨率/格式/lane）、`I_dsi_en` 使能机制、以及无摄像头自检入口 |
| 新增配置区 | 在端口声明后新增 `localparam`：<br/>`H_ACTIVE=1920`、`V_ACTIVE=1080`、`W_BEATS_PER_LINE=H_ACTIVE/4`、`R_BEATS_PER_LINE=H_ACTIVE/2`、`H_SA/H_BP/H_FP/V_SA/V_BP/V_FP` |
| `ui_dbuf` 例化 | 写侧 `W_XSIZE/W_XSTRIDE = W_BEATS_PER_LINE`、`W_YSIZE = V_ACTIVE`；<br/>读侧 `R_XSIZE/R_XSTRIDE = R_BEATS_PER_LINE`、`R_YSIZE = V_ACTIVE`（原为硬编码 `480/480/1080`、`960/960/1080`）|
| `ui_vtc` 例化 | 行/场时序改为由 `H_ACTIVE/V_ACTIVE` + 消隐参数推导（原为 `1920+88`、`1920+88+44`、`1920+88+44+148` 之类硬编码）|
| `csi2_pack_yuv422_stream` | `.H_ACTIVE/.V_ACTIVE` 改接 `localparam` |
| `csi2_frame_tx` | `.H_ACTIVE/.V_ACTIVE` 改接 `localparam`；`DT` 注释标明必须与 RK 驱动 `MEDIA_BUS_FMT_YUYV8_2X8` 一致 |

> **数值等价性**：改写后的表达式求值与原硬编码完全相同
> （`2200/1125` 行长行数、`480` 写突发、`960` 读突发），
> 因此**综合结果与官方 bit 功能一致**，改动只是为了后续改分辨率时不容易改漏。

### 2. 其它
- `system_top_tx_tpg.v` / `yuv422_tpg_axis.v` / `fpga_pin_tx_tpg.adc` / `timing_tx_tpg.sdc`
  —— 官方原有的「无摄像头测试图案」通路，**保留未改动**，在 README 中补充了使用说明。
- 其余 RTL / IP / 约束文件：**未修改**。

---

## 二、RK3576 端（`rk/`）

### 1. 从参考材料引入（未修改）
- `rk/boot.img` ← `07_异构方案/boot.img`
- `rk/driver/milianke_mipi.c`、`rk/driver/Kconfig`、`rk/driver/Makefile` ← `07_异构方案/driver/`
- `rk/dts/` ← `07_异构方案/dts/`
  （关键节点：`rockchip/rk03/csi-imx415-2.dtsi`，把 FPGA 挂成 `milianke,fpga-virtual`）

### 1b. 驱动已修改：修正色彩空间声明 ★
`rk/driver/milianke_mipi.c` 的 `milianke_get_fmt()`：

```c
- fmt->format.colorspace = V4L2_COLORSPACE_SRGB;      /* 默认 full range */
+ fmt->format.colorspace   = V4L2_COLORSPACE_REC709;
+ fmt->format.ycbcr_enc    = V4L2_YCBCR_ENC_709;
+ fmt->format.quantization = V4L2_QUANTIZATION_LIM_RANGE;
+ fmt->format.xfer_func    = V4L2_XFER_FUNC_709;
```

原因：FPGA 侧 `rgb_to_yuv422_quad.v` 输出的是 **BT.709 + limited range**，
而 `V4L2_COLORSPACE_SRGB` 隐含 full range，导致 rkcif/rkisp 按 full 解释
limited 数据 → 黑电平抬高、白点只到 235、色度欠饱和（画面发灰发绿）。
这一项同时修好 **HDMI/kmssink 路径**（该路径依赖驱动声明的色彩信息）。

> 该驱动在 `boot.img` 里是内置（`=y`），要让改动生效需重编内核/boot.img，
> 或改为 `=m` 编成 `.ko` 后 insmod。详见 `rk/web/README.md` 第 10 节。

### 2. 新增文件（本次编写）
| 文件 | 作用 |
|------|------|
| `rk/deploy/rk_mipi_selftest.sh` | 6 步链路自检：内核信息 → 设备树节点 → 驱动注册/I2C 绑定 → 枚举 `/dev/video*` → 抓 10 帧到 `fakesink` → 提示 HDMI 出图。**不依赖显示器**，先定位 FPGA→MIPI→RK 是否通 |
| `rk/deploy/test_hdmi.sh` | 自动查找 FPGA 采集节点并 `gst-launch-1.0 ... ! kmssink` 全屏出图；支持 `save` 模式抓一帧存 PNG |
| `rk/deploy/README.md` | RK 端完整部署步骤（刷机、刷 boot 分区三种方式、跳线帽、上电顺序、常见问题表、驱动参数说明）|
| `rk/driver/build_module.sh` | 可选：把 `milianke_mipi.c` 独立编译成 `.ko`（当内核未内置该驱动时使用），自动处理 kernel headers |
| `rk/web/mipi_webstream.py` | RK 端 HTTP MJPEG 推流服务 + 调参 API（默认 9012）；四种采集后端 `gstlive`(gi/GStreamer 原生，参数在线生效) / `opencv`(cv2 逐帧处理) / `gst`(gst-launch 兜底) / `test`(videotestsrc 测试图案) |
| `rk/web/mipi_viewer.html` | PC 端本地网页：拉流看画面 + 滑块调参 + 抓拍下载，纯静态、双击即可打开（带 CORS 支持）|
| `rk/web/start_webstream.sh` | 一键启动；**自动挑选“能 import cv2 的解释器”**（本板为 conda 环境 `mlk-ov`）|
| `rk/web/cv2_probe.py` | 探测指定解释器下 OpenCV 能否打开各 `/dev/video*`，并实测 3 秒帧率 |
| `rk/web/color_diag.py` | 颜色诊断：把「U/V 顺序 × 601/709 × limited/full」全部渲染出来对比，并打印 Y/Cb/Cr 统计 |
| `rk/web/color_verify.py` | 把 GStreamer 输出与已知正确的转换结果逐像素比对（线性回归 + RMS）|
| `rk/web/bench_stages.py` | 逐阶段计时（read / 转换 / JPEG 编码），定位性能瓶颈 |
| `rk/web/bench_new.py` | 优化前后的 YUV→BGR 实现对比：耗时 + 数值一致性 |
| `rk/web/gst_tune_test.sh` | 原生 GStreamer 各种管线的吞吐测试 + 颜色对照 |

### 2b. 帧率优化（同画质 9.3 → 22.1 fps）★

`rk/web/mipi_webstream.py` 两处改动：

1. **`yuv_to_bgr()` 改用 int16 查找表 + `cv2.LUT`**
   - 把「limited→full 量程展开」与「BT.709 矩阵系数」合并预计算成 256 项 int16 表
   - 查表必须用 `cv2.LUT`(SIMD)；numpy 花式索引 `lut[u8]` 会慢十几倍
   - 全程整数、去掉 `np.rint`、原地裁剪写预分配缓冲
   - 转换耗时 `53.7ms → 29.8ms`，**逐像素最大差仅 1 LSB**（真正等价）

2. **修掉限帧 bug**：原 `time.sleep(dt - 0.004)` 固定睡掉整个帧周期，
   把处理耗时又重复计了一遍，每帧白等 ~36ms，硬把 22fps 压到 12fps。
   改为只补足剩余时间。

> 试过但**放弃**的更激进方案：`cv2.cvtColor(COLOR_YUV2BGR_YUYV)` + `cv2.transform`
> 修正 601→709（只要 4.5ms），但与手写实现有 82% 像素差 >8、最大差 31，不等价。
> 同理放弃 `gstlive`（原生管线 37.4fps）作为默认 —— 本机 GStreamer 的
> `videoconvert` 不做 16-235 展开且 `capssetter` 无效，会掉画质。
> 两者都保留为可选，详见 `rk/web/README.md` 第 11 节。
| `rk/web/README.md` | 网页推流部署步骤、运行环境实测结论、采集后端对比、HTTP API 速查、调优与排错 |
| `rk/deploy/env_check.sh` | 板上环境自检：逐个 Python 解释器探测 cv2/numpy/PIL/gi、GStreamer 元素、采集节点与 format |

---

## 三、工程级新增

| 文件 | 作用 |
|------|------|
| `README.md` | 总部署指南（框图、硬件准备、FPGA/RK 双端步骤、上电顺序、自检方法、改分辨率指引）|
| `MODIFICATIONS.md` | 本文件 |
| `docs/` | 官方 MIPI 教程（PDF + 提取的文本）、AFC03 硬件手册文本 |
| `fpga_reference_src.zip` | 官方原始例程备份 |

---

## 四、未做的事（如需请告知）

- 未重新综合/布线生成新 bit —— 现有 `fpga_prj_compress.bit` 仍为官方 bit。
  因为本次改动在数值上等价，可直接复用；若你要一个「重新综合过」的 bit，
  在 TD 里对 `syn_1` / `phy_1` 重新 Run 即可（预期结果一致）。
- 未包含 YOLO 识别与开机自启动部分（参考材料 `415_mipi/yolo识别+自启动/` 里有，
  教程第二章/第三章有说明），本项目聚焦「采集→传输→显示」链路测试。
