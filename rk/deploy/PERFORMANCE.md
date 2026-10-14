# 帧率能力实测报告（能不能做到 1080p60）

平台：MLK-AFC03（RK3576J + 安路 PH1A90SEG324），驱动 `rkcif-mipi-lvds3`，节点 `/dev/video22`
采集格式：NV16 1920x1080（YUV422），链路：FPGA → MIPI x4 → RK3576

> 1080p60 的预算是 **16.7 ms/帧**。

---

## 1. 总结论

| 通路 | 最初 | 优化后 | 1080p60 |
|------|------|--------|---------|
| **FPGA→RK 采集链路** | 59.2 fps | 59.2 fps | ✅ **已经是 60** |
| **网页 MJPEG 1920x1080** | 22.1 fps | **59.6 fps** | ✅ **已达成** |
| **HDMI 输出（kmssink）** | 27.7 fps | **53.7 fps** | ⏳ 89% |
| 网页 MJPEG 960x540 | — | 57.0 fps | — |

**一句话**：**链路本来就是 1080p60，网页也做到了 1080p60。**
关键是发现瓶颈根本不是"算力不够"，而是**管线串行**（采集/转换/编码排队跑）
和 **CPU 亲和性**（进程被调度到 A53 小核上，白丢一半性能）。

> 顺带一个重要结论：**JPEG 压缩不需要放到 FPGA 端。**
> RK3576 软件编码留了 3.6 倍余量（见 §7），而 rkcif 这条 MIPI 采集链路上报的
> 全是 YUV 格式，**根本没有 `V4L2_PIX_FMT_JPEG`**，硬件 JPEG 码流也送不进来。
> 真要做就得把互联换成 PCIe 并改自研驱动，收益却是零。

### 1.1 网页通路的三次优化（22.1 → 59.6 fps）

| 阶段 | 改动 | 帧率 |
|------|------|------|
| 起点 | numpy 版 YUV→BGR，单线程串行 | 22.1 fps |
| ① 串行 → 三级流水线 | 采集 / 转换 / 编码分属不同线程 | ~30 fps |
| ② 色彩转换换成 C | `libyuvconv.so`，逐像素结果不变 | ~45 fps |
| ③ C 转换按行切分并行 | 4 线程并发调用 | **59.6 fps** |

瓶颈最终回到**采集本身 16.8ms/帧（59.6 fps）** —— 也就是链路上限，这正是目标。

#### 各段实测耗时（1920x1080，A72 核）

| 阶段 | 原实现 | 优化后 |
|------|--------|--------|
| 采集 `cap.read()` | 16.8 ms | 16.8 ms（链路上限） |
| YUV→BGR | **67.2 ms** | **7.9 ms**（C + 4 线程） |
| JPEG 编码 | 18.2 ms | **6.1 ms**（3 线程） |
| **串行合计** | 102.3 ms → 9.8 fps | — |
| **流水线取最大** | — | **16.8 ms → 59.6 fps** |

#### 为什么不能用 OpenCV 自带的 `cvtColor`

`cv2.cvtColor` 只要 4.5ms，但它按 **BT.601 + full range** 解释，
而本工程 FPGA 送的是 **BT.709 + limited(16~235)**，直接用会偏灰偏绿
（这正是最初"颜色很奇怪"的原因）。所以用 C 重写了同一套整数查表算法，
逐像素与 numpy 版**完全一致（max diff = 0）**。

---

## 2. 采集链路能力（关键：链路本身就够了）

| 测试 | 耗时 | 帧率 |
|------|------|------|
| `v4l2-ctl` 直接抓 NV16（纯 C，无 Python） | 16.9 ms/帧 | **59.2 fps** |
| `gst v4l2src ! fakesink` | 17.4 ms/帧 | 57.6 fps |

→ **FPGA→RK 的 MIPI 链路实际就在以 ~60fps 送 1920x1080**，与 FPGA 侧
`ui_vtc`（2200×1125 @148.5MHz）和 `csi2_frame_tx`（byte_clk 75MHz、
GAP_LINE=200/GAP_FRAME=4000，算下来 ≈59.6fps）的设计目标一致。
内核也印证了：`rkcif-mipi-lvds3: vblank ... cur 666 us` → 帧周期 ≈ 60Hz。

### 2.1 是"真 60fps"还是"重复帧凑数"？

`dup_check.py` 抓 40 帧逐帧比较（相邻帧平均绝对差）：

```
抓到 40 帧 (每帧 4147200 字节)
  min=0.000  中位=0.999  max=1.262
  几乎完全相同(重复帧)的相邻对: 3 / 39
```

场景是静态桌面，若 FPGA 把同一帧重复两遍，相邻差会**恰好等于 0**。
实测中位数 ≈1.0（传感器逐帧独立噪声），只有 3/39 是重复。
→ **送的是真实 ~60fps 内容**，不是 30fps 复制成 60fps。

---

## 3. 编码环节能力（瓶颈在这里）

每组 300 帧：

| 方案 | 耗时 | 帧率 |
|------|------|------|
| 软件 `jpegenc` 1080p（无 queue） | 34.1 ms/帧 | 29.3 fps |
| 软件 `jpegenc` 1080p **+ queue** | **24.1 ms/帧** | **41.5 fps** |
| `mppjpegenc`（RK 硬件 MPP）1080p | 25.6 ms/帧 | 38.9 fps |
| 软件 `jpegenc` 720p + queue | 25.8 ms/帧 | 38.8 fps |
| 软件 `jpegenc` 960x540 + queue | **17.5 ms/帧** | **57.0 fps** |

结论：

- **`queue` 很关键**：`v4l2src ! queue ! jpegenc` 让采集与编码在不同线程重叠，
  吞吐从 29.3 → 41.5 fps。之前的管线没有 queue，耗时是「采集 + 编码」相加的。
- **`mppjpegenc` 没发挥出硬件应有的水平**（25.6 ms/帧，还不如软件 + queue）。
  可能要改用 MPP 原生接口或调 `bps`/`max-pending`，但板上没有
  `/dev/video-encoder` 这个 V4L2-M2M 节点，只有 `/dev/mpp_service`。
- **`videoscale` 也不便宜**：1080p→720p 缩放本身要 ~8ms，所以 720p 反而比 1080p 慢。
- **CPU 侧碰像素很贵**：`videotestsrc 1080p → fakesink` 只有 24.8 fps，
  说明纯粹在 CPU 上生成/搬 1080p 像素就要 40ms。这也解释了为什么
  OpenCV/Python 路线封顶在 22 fps。

---

## 4. HDMI 通路：27.7 → **53.7 fps**（优化过程）

### 4.1 优化前的现状

```
cat /sys/kernel/debug/dri/0/summary
```

```
Video Port0: ACTIVE
    Connector:HDMI-A-1  Encoder: TMDS-187
    Display mode: 1440x900p60          <-- 显示器当前跑 1440x900@60
        dclk[106500 kHz]
    Esmart0-win0: format: XR24 (RGBA8888)
        src: rect[1440 x 900]  dst: rect[1440 x 900]
```

连接器能力里**有 1920x1080@60**（`modetest -c` 第 #1 项，148.5MHz），
但 EDID 的 **preferred 是 1440x900@59.89**，所以 KMS 选了 1440x900。

原来 `v4l2src ! kmssink` 只有 27.7 fps，且与输入格式（NV16/NV12）、
是否加 videoconvert 都无关 —— **一度以为是链路或 KMS 的硬限制，其实不是。**

### 4.2 真正的原因：管线串行

采集和上屏跑在同一个线程里，耗时是「采集 17ms + 上屏 20ms」**相加**。
插入 `queue` 后两者并行，吞吐变成**取最大值**。

### 4.3 实测扫描

| 管线 | fps | 耗时 |
|------|-----|------|
| `v4l2src ! kmssink` | 27.7 | 36.1 ms |
| `v4l2src ! queue(4) ! kmssink` | 36.2 | 27.6 ms |
| `v4l2src ! queue(16) ! kmssink` | 29.4 | 34.0 ms |
| `v4l2src ! queue(4) ! videoconvert ! queue(4) ! kmssink` | 49.8 | 20.1 ms |
| **`v4l2src ! queue(4) ! videoscale 1440x900 ! queue(4) ! kmssink`** | **53.7** | **18.6 ms** |

queue 深度也有讲究（**双 queue 时**）：2 → 37.6 fps；3 → 49.6；4 → 49.8；
6 → 49.9；8 → 49.8。**3~8 是甜区**，太浅（2）或太深（16）都会掉。

### 4.4 推荐命令（可直接用）

```bash
# 1080p 采集 -> 缩放到屏幕原生 1440x900 -> HDMI，实测 53.7 fps
gst-launch-1.0 v4l2src device=/dev/video22 ! \
  video/x-raw,width=1920,height=1080 ! \
  queue max-size-buffers=4 ! \
  videoscale ! video/x-raw,width=1440,height=900 ! \
  queue max-size-buffers=4 ! \
  kmssink
```

**53.7 fps 已经是采集上限 57.6 fps 的 93%** —— 也就是说显示这条路
**基本已经摸到链路的上限**了。想再往上，需要把显示器模式改成
`1920x1080@60`（这样连 videoscale 都可以省掉）：

```bash
modetest -M rockchip -s <connector_id>@<crtc_id>:1920x1080-60
# connector_id / crtc_id 用 modetest -c 查（本机 connector=188）
```

---

## 5. 结论与建议

**要 1080p60，先别怀疑链路，也别急着加硬件 —— 先看管线有没有并行。**

| 目标 | 现在 | 建议 |
|------|------|------|
| **网页 1920x1080** | **59.6 fps** | ✅ 已达成，默认启动即此配置 |
| **HDMI 显示** | **53.7 fps** | 把显示器设成 1920x1080@60 可再试 |
| 更省 CPU | — | `--stream-width 1280` 或 `960` |

### 关于「帧率上限」参数（1 ~ 120）

网页上的「帧率上限」已经放宽到 **120**，但它只是个**限速阀**，不是目标值：

- 本工程 FPGA 链路固定输出 **1080p60**，所以**填 60 以上等于不限速**，
  实测结果仍是 **~59.6 fps**（占满链路，不会更高）。
- **想真的超过 60fps，必须改 FPGA**：`ui_vtc` 的 2200x1125@148.5MHz 时序、
  PLL 频率、`csi2_frame_tx` 的 byte_clk / GAP_LINE / GAP_FRAME，
  以及 IMX415 的读出模式（`ui_imx415_reg.v` 的 VMAX/HMAX）都要重算。
  这不是 MIPI 带宽问题（4 lane 还有余量），而是**源端根本没有那么多帧**。
- `videorate` 的坑：它的语义是**重采样**而不是限速。若把 caps 设成比源更高的
  帧率，它会**复制帧**来凑数（帧率看着翻倍、内容一帧没多、白吃 CPU）。
  已改成 `drop-only=true` + 区间 caps，让 60fps 原样通过。

**摄像头本身不是瓶颈**：IMX415 支持 1080p60，当前 FPGA 确实在输出 60fps 真实画面
（`dup_check.py` 已排除"30fps 重复成 60fps"）。

**已知遗留问题**：

1. **HDMI 上颜色还是不对** —— 驱动色域补丁编进了 `boot.img`（`=y`），
   必须重新编译 boot.img 才生效。软件侧（网页）已经修好。
2. **画面偏亮（过曝）** —— IMX415 曝光/增益偏高（FPGA `ui_imx415_reg.v`），
   与颜色解析无关。实测快照灰度均值 226/255。

---

## 6. 复现脚本

```bash
pkill -f 'mipi_web[s]tream'

# 优化后的推流（默认已是 1080p60 配置）
cd /root/rk/web && ./start_webstream.sh

# 编译 C 色彩转换加速库（第一次或换架构时跑）
./build_yuvconv.sh

# —— 帧率相关 ——
cd /root/rk/deploy
./rate_test.sh     /dev/video22 300    # 采集链路 vs 各级处理
./jpeg_enc_test.sh /dev/video22 200    # 各编码器枚举 + 吞吐
./overlap_test.sh  /dev/video22 300    # queue 带来的并行收益
./affinity_test.sh /dev/video22 300    # 大小核差异（21.8 vs 41.4 fps）
./display_test.sh  /dev/video22 300    # 显示通路 vs 采集通路
./kms_tune2.sh     /dev/video22 300    # kmssink 最佳参数锁定
./test_pipeline.sh 12                  # 启动推流服务并测真实帧率

# —— 分析与校验 ——
/opt/miniforge3/envs/mlk-ov/bin/python ../web/dup_check.py        /dev/video22  # 重复帧检测
/opt/miniforge3/envs/mlk-ov/bin/python ../web/bench_pipeline.py   /dev/video22  # 各段耗时
/opt/miniforge3/envs/mlk-ov/bin/python ../web/bench_conv.py                     # 分条并行扩展性
/opt/miniforge3/envs/mlk-ov/bin/python ../web/test_yuvconv.py                   # C 库正确性+速度
/opt/miniforge3/envs/mlk-ov/bin/python ../web/enc_bench.py       /dev/video22  # 编码多核扩展性
cat /sys/kernel/debug/dri/0/summary    # 当前 HDMI 模式
```

---

## 7. 关于「把 JPEG 压缩放到 FPGA 端」

已经完整论证过，**结论是不必要，而且在这块板子上走不通**：

### 7.1 没有现成的官方 JPEG 例程可改

全工作区 grep `jpeg|mjpeg|jfif|huffman|zigzag`，命中的全部是加密 IP（`.enc.v`）
里的 base64 噪声；`uisrc/03_ip/` 下只有 al_fifo / dphy_tx_general / mipi_dsi /
ui_ae_set / ui_csi_raw / ui_dbuf / ui_fdma / ui_imx415_cfg / ui_isp /
ui_setvbuf / ui_vtc —— **没有任何 JPEG 编码 IP**。
要从零手写 DCT + 量化 + 霍夫曼 + 位打包，大约 3000~5000 行 RTL。

### 7.2 就算写出来，MIPI 这条链路也传不进来

```
v4l2-ctl -d /dev/video22 --list-formats-ext
  [0] NV16  [1] NV61  [2] NV12  [3] NV21
  [4] YUYV  [5] YVYU  [6] UYVY  [7] VYUY
```

**全是 YUV，没有 `V4L2_PIX_FMT_JPEG`**。rkcif 是硬件 raw 采集通路，
它不解析 JPEG 码流，也没法把它当作一个像素格式上报给用户态。
（只有 `07_异构方案/AFC03_IMX415_PCIE_X1` 那条 PCIe 路，
因为用的是自研 V4L2 驱动 `milianke_v4l2_zerocopy.c`，格式可以自由改成 MJPEG。）

### 7.3 而且根本不需要 —— RK 软件编码余量很大

`enc_bench.py` 实测（绑 A72 核，1080p q80）：

| 方案 | 帧率 |
|------|------|
| `cv2.imencode` 单核 | 55.8 fps |
| `cv2.imencode` 4 核并行 | **220.2 fps**（加速比 3.95x） |
| GStreamer `jpegenc` 单核 | 41.4 fps |

需求只有 60fps，**余量 3.6 倍**。真要优化，收益最高的是
「绑大核 + 多线程 + 缩短管线」，而不是上 FPGA。

> 顺带查到：RK3576 只有 `jpegd@27910000`（**硬件 JPEG 解码器**），
> 没有硬件编码器 —— 这就是 `mppjpegenc` 只有 25.6ms/帧、跟软件差不多快的原因。
> 反过来，如果哪天需要硬件**解码** JPEG，`jpegd` 是可以用的。
