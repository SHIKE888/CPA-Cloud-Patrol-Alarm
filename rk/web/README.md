# MIPI 网页推流 + 远程调参

把 RK3576 上采集到的画面推到 **`<RK的IP>:9012`**，PC 上用 `mipi_viewer.html`
即可看画面并在线调节画面参数。

```
┌──────────────┐  MIPI x4   ┌──────────┐   HTTP MJPEG :9012   ┌────────────────────┐
│ FPGA 采集    │ ─────────► │ RK3576   │ ───────────────────► │ PC 浏览器          │
│ MIPI → ISP   │            │ mipi_web │ ◄─────────────────── │ mipi_viewer.html   │
└──────────────┘            │ stream.py│   /api/params (调参)  └────────────────────┘
                            └──────────┘
```

---

## 0. 运行环境（本板实测结论，先看这里）

RK3576 Debian 上装了**两套 Python**，依赖是分开的：

| 解释器 | cv2 | numpy | PIL | gi / GStreamer | 适用后端 |
|--------|-----|-------|-----|----------------|----------|
| `/usr/bin/python3` (3.11.2, 系统) | ✗ | ✗ | ✗ | **✓** | `gstlive` |
| `/opt/miniforge3/envs/mlk-ov/bin/python` (3.8.20, conda) | **✓ 5.0.0** | ✓ 1.24.4 | ✗ | ✗ | `opencv` |

**结论：想用 OpenCV 调参，必须用 conda 环境 `mlk-ov` 的解释器。**

```bash
# 手动验证
/opt/miniforge3/envs/mlk-ov/bin/python -c 'import cv2; print(cv2.__version__)'
/opt/miniforge3/envs/mlk-ov/bin/python rk/web/cv2_probe.py     # 探测各采集节点
```

`start_webstream.sh` 会**自动挑“能 import cv2 的解释器”**，所以直接跑就行；
也可以手动指定：

```bash
PYTHON=/opt/miniforge3/envs/mlk-ov/bin/python ./start_webstream.sh
```

### 采集节点实测（`cv2_probe.py` 结果）

| 节点 | 类型 | 能否读帧 |
|------|------|----------|
| `/dev/video22` | rkcif（Multiplanar） | **✓ 1920x1080 @59.6fps**（NV16，`CONVERT_RGB=0`）|
| `/dev/video33` / `/dev/video51` | rkisp_mainpath | ✗ select() timeout |

所以**用 `/dev/video22`**（与米联客教程一致）。
注意它是 `Video Capture Multiplanar` 节点，只有 OpenCV 5.x 才支持，所以 `mlk-ov` 环境是必须的。

> OpenCV 版：`cv2 5.0.0` / `numpy 1.24.4` / Python 3.8.20

---

## 1. 文件

| 文件 | 说明 |
|------|------|
| `mipi_webstream.py` | RK 端服务：抓流 → JPEG → HTTP MJPEG 推流 + 调参 API（**默认端口 9012**）|
| `mipi_viewer.html` | PC 端本地网页：看画面 + 调参（纯静态，双击即可打开）|
| `start_webstream.sh` | 一键启动脚本 |

---

## 2. 部署到 RK3576

```bash
# 从 PC 拷贝（已配好免密的话可以直接用 ssh 别名 afc03）
scp -r rk/web/ afc03:/root/rk/
ssh afc03
cd /root/rk/web && chmod +x *.sh

# 启动（默认 /dev/video22 : 9012）
#   -> 会自动挑到 /opt/miniforge3/envs/mlk-ov/bin/python，走出 OpenCV 后端
./start_webstream.sh

# 或指定节点 / 端口 / 降低负载
./start_webstream.sh /dev/video22 9012 --stream-width 960 --quality 70 --fps 20
```

启动后会打印解释器、后端与实际可访问地址，例如：

```
 MIPI 网页推流
   Python : /opt/miniforge3/envs/mlk-ov/bin/python
   设备   : /dev/video22
   端口   : 9012
   地址   : http://192.168.137.100:9012/
```

> **关于 `192.168.137.100`**：这是 **RK3576 的 IP**（图里是服务端）。
> 如果你的板子拿到的是别的地址，以启动时打印的为准。

---

## 3. PC 上查看

### 方式 A（推荐）：本地网页 `mipi_viewer.html`
1. 把 `mipi_viewer.html` 拷到 PC，**双击打开**（`file://` 直接可用，不需要起服务器）
2. 顶部地址框填 **`192.168.137.100:9012`**（RK 的 IP:端口），点「连接」
3. 左侧出画面，右侧调参

> 也可以用 `mipi_viewer.html#192.168.137.100:9012` 直接带上地址打开。
> 地址会记在 `localStorage`，下次自动填。

### 方式 B：直接开 RK 上的页面
```
http://192.168.137.100:9012/
```

### 方式 C：只有一行 gst（不需要 Python，但没有在线调参）
```bash
# RK 上：监听 9012，用 multipart MJPEG 推流
gst-launch-1.0 v4l2src device=/dev/video22 \
  ! jpegenc quality=80 \
  ! multipartmux boundary=frame \
  ! tcpserversink host=0.0.0.0 port=9012
```
然后浏览器打开 `http://192.168.137.100:9012`（Chrome/Edge 能直接显示 MJPEG）。

---

## 4. 「主动推流到 PC」的模式（可选）

上面是 **RK 当服务端**（PC 拉流）。如果你确实要让 **RK 主动连到 PC 的 9012**：

```bash
# RK 上：主动连到 PC 的 192.168.137.100:9012
gst-launch-1.0 v4l2src device=/dev/video22 \
  ! jpegenc quality=80 ! multipartmux boundary=frame \
  ! tcpclientsink host=192.168.137.100 port=9012
```

PC 上需要先起一个接收端（例如装了 GStreamer 的话）：

```bash
gst-launch-1.0 tcpserversrc port=9012 ! multipartdemux ! jpegdec ! autovideosink
```

这种模式 **浏览器无法直接接收**（没有 HTTP 头），所以 `mipi_viewer.html`
默认走的是第 3 节的「RK 当服务端」模式 —— 效果一样，而且更通用。

---

## 5. 采集后端（`--backend`）

`auto`（默认）按 **gstlive → opencv → gst** 的顺序挑第一个可用的。

| 后端 | 依赖 | 画面参数实现 | 说明 |
|------|------|--------------|------|
| `gstlive` | `gi` + GStreamer | `videobalance`/`gamma`/`videoflip`/`videoscale` 元素，**改属性即时生效** | 原生 C 实现，CPU 最低；系统 `python3` 里可用 |
| `opencv` | `cv2`（`mlk-ov` 环境）| Python 逐帧处理，改参数即时生效 | 参数最全；本板实测 1920x1080 **59.6 fps**（C 加速 + 三级流水线）|
| `gst` | `gst-launch-1.0` | ✗（只能靠 V4L2 硬件参数）| 最后兜底 |
| `test` | 无 | 同 `gstlive` | **不接摄像头/不接 FPGA**，用 `videotestsrc` 验证网页链路 |

```bash
./start_webstream.sh /dev/video22 9012 --backend opencv    # 强制 OpenCV
./start_webstream.sh x 9012 --backend test                 # 测试图案验证网页
PYTHON=python3 ./start_webstream.sh /dev/video22 9012 --backend gstlive   # 走系统 python3
```

---

## 6. 可调参数

### 6.1 软件参数（`POST /api/params`，立即生效、不断流）

| 参数 | 范围 | 说明 |
|------|------|------|
| `brightness` | -100 ~ 100 | 亮度偏移 |
| `contrast` | 0.2 ~ 3.0 | 对比度增益 |
| `saturation` | 0.0 ~ 3.0 | 饱和度 |
| `hue` | -180 ~ 180 | 色相旋转（度）|
| `gamma` | 0.2 ~ 3.0 | 伽马 |
| `mirror` / `flipv` | 0/1 | 水平镜像 / 垂直翻转 |
| `rotate` | 0/90/180/270 | 旋转 |
| `scale` | 0.25 ~ 1.5 | 相对 `--stream-width` 的缩放 |
| `quality` | 30 ~ 95 | JPEG 质量 |
| `fps` | 1 ~ 120 | 推流帧率上限（本工程链路固定 1080p60，实测封顶 ≈59.6fps）|

返回体里带 `{"reset": true}` 可恢复默认。

### 6.2 硬件参数（`/api/controls` 自动发现 + `POST /api/ctrl` 设置）
自动执行 `v4l2-ctl -d <dev> --list-ctrls`，把可写的整数/布尔/菜单控件做成滑块。
这些是 **ISP / 传感器** 级别的真实调节（不占用 RK CPU）。

> 如果列表为空，说明该采集节点没有可调硬件参数（rkcif 采集节点常见），
> 这属于正常现象，用软件参数即可。

---

## 7. HTTP API 速查

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/` | 内置页面（若同目录有 `mipi_viewer.html` 则直接返回它）|
| GET | `/stream` | `multipart/x-mixed-replace` MJPEG 流 |
| GET | `/snapshot.jpg` | 取当前一帧 JPEG |
| GET | `/api/params` | 读取当前软件参数 |
| POST | `/api/params` | 修改软件参数（JSON，可只传部分字段）|
| GET | `/api/controls` | 列出 V4L2 硬件可控参数 |
| POST | `/api/ctrl` | `{"name":"brightness","value":128}` |
| GET | `/api/status` | 后端 / 设备 / 分辨率 / 实际帧率 / 客户端数 |

所有 API 都带 `Access-Control-Allow-Origin: *`，所以 `file://` 打开的本地 HTML
也能直接调用。

命令行验证：

```bash
curl http://192.168.137.100:9012/api/status
curl -X POST http://192.168.137.100:9012/api/params \
     -H 'Content-Type: application/json' -d '{"brightness":20,"saturation":1.4}'
curl http://192.168.137.100:9012/api/controls
# VLC 直接放流
vlc http://192.168.137.100:9012/stream
```

---

## 8. 常用调优

| 现象 | 处理 |
|------|------|
| 画面卡顿 / CPU 高 | `--stream-width 960 --quality 65 --fps 15`，或网页里把「输出缩放」拉到 0.5，或改用 `--backend gstlive`(系统 python3，原生管线，CPU 低很多) |
| 提示 `cv2 不可用` | 用错解释器了：OpenCV 只在 conda 环境里。直接跑 `./start_webstream.sh` 会自动选；或 `PYTHON=/opt/miniforge3/envs/mlk-ov/bin/python ./start_webstream.sh` |
| 提示 `gi 不可用` | 正常（`mlk-ov` 环境没有 gi）。想用 GStreamer 原生管线就 `PYTHON=python3 ./start_webstream.sh --backend gstlive` |
| 打不开画面 | `curl http://<RK>:9012/api/status` 看服务是否活着；确认 PC 与 RK 同网段、防火墙放行 9012 |
| `<img>` 一直黑 | 用 `curl -I http://<RK>:9012/stream` 确认返回 200 + `multipart/x-mixed-replace` |
| 抓到的帧全黑（但有噪点）| 图像数据是通的，通常是**镜头对着暗处/被挡住**，或 IMX415 曝光偏低。可先把「亮度/对比度」拉高确认；网页有画面后即可判断 |
| 提示打开 `/dev/video22` 失败 | 先跑 `../deploy/rk_mipi_selftest.sh` 确认节点；或 `../deploy/env_check.sh` 看环境 |
| 想让 PC 开机自动看 | 浏览器快捷键 / 用 `mipi_viewer.html#<RK_IP>:9012` 做快捷方式 |

---

## 9. 开机自启（可选）

在 `/etc/rc.local` 的 `exit 0` 之前加：

```sh
# 等网络就绪
( sleep 20; cd /root/web && ./start_webstream.sh /dev/video22 9012 ) > /var/log/webstream.log 2>&1 &
```

---

## 10. 颜色为什么怪？—— 根因与修复

### 10.1 根因：YUV 量程/矩阵不匹配

| 环节 | 实际使用 |
|------|----------|
| **FPGA 输出** | **BT.709 + limited range（16~235）** |
| **RK 驱动声明** | `V4L2_COLORSPACE_SRGB` → 默认 **full range（0~255）** |
| **OpenCV 解码** | 按 full range 处理 |

证据（两条独立来源）：

1. **RTL 源码** `fpga/uisrc/03_ip/mipi_dsi/rgb_to_yuv422_quad.v`
   ```
   Y  =  0.183R + 0.614G + 0.062B + 16
   Cb = -0.101R - 0.338G + 0.439B + 128
   Cr =  0.439R - 0.399G - 0.040B + 128
   ```
   系数和 `0.183+0.614+0.062 = 0.859 = 219/255`，且
   `(0.2126, 0.7152, 0.0722) x 219/255 = (0.1826, 0.6142, 0.0620)`
   → **与 BT.709 完全吻合**（若是 BT.601 应为 0.257/0.504/0.098）。
   `+16` 偏移说明黑点=16、白点=235，即 **limited range**。

2. **实测**（`color_diag.py` 抓原始 NV16）：`Y min=22  max=234`
   → 白点落在 235（limited），不是 255。

把 limited 数据当 full 处理，后果就是：黑电平被抬到 16/255（发灰）、
白点只到 235（不够亮）、色度偏差被压缩（**欠饱和 + 发绿**）。

### 10.2 已做的修复

**① 网页推流（已修复，立即生效）**

`mipi_webstream.py` 现在：
- 用 `CAP_PROP_CONVERT_RGB=0` 让 OpenCV **别自己转**，直接取原始 YUV422 缓冲；
- 自己按 **BT.709 + limited** 转换（`yuv_to_bgr()`）；
- 并且**先在 YUV 域缩放到推流尺寸再转换**，省掉一大半浮点运算。

可选参数（默认值就是本工程正确的组合）：

```bash
./start_webstream.sh /dev/video22 9012 \
    --fourcc NV16 --yuv-matrix 709 --yuv-range limited
# 如果颜色明显不对(比如红蓝颠倒), 加 --swap-uv 试试
```

**② HDMI / kmssink 路径（需要重新编译内核）**

`kmssink` 这条路用的是驱动声明的色彩信息，所以必须改驱动。
`rk/driver/milianke_mipi.c` 里已改好：

```c
fmt->format.colorspace   = V4L2_COLORSPACE_REC709;   /* 原: V4L2_COLORSPACE_SRGB */
fmt->format.ycbcr_enc    = V4L2_YCBCR_ENC_709;
fmt->format.quantization = V4L2_QUANTIZATION_LIM_RANGE;
fmt->format.xfer_func    = V4L2_XFER_FUNC_709;
```

这个驱动在 `boot.img` 里是**内置（=y）**的，所以要让改动生效需要：

- 用 RK3576 SDK 重新编译内核 + dtb，重新生成 `boot.img`（见
  [`../deploy/README.md`](../deploy/README.md) 1.2 的方式 C）；或
- 把该驱动配置为 `=m` 后编译成 `.ko`，用
  [`../driver/build_module.sh`](../driver/build_module.sh) 生成并 `insmod`
  （需要先把内核里的内置版本关掉，否则重名冲突）。

### 10.3 诊断工具

```bash
# 1) 环境探测(会逐个解释器检查 cv2/gi, 列出采集节点)
./../deploy/env_check.sh

# 2) 各采集节点能否出帧
/opt/miniforge3/envs/mlk-ov/bin/python cv2_probe.py

# 3) 颜色诊断: 把 U/V顺序 x 601/709 x limited/full 全部渲染出来对比
pkill -f 'mipi_web[s]tream'          # 先释放设备
/opt/miniforge3/envs/mlk-ov/bin/python color_diag.py /dev/video22
#   -> /tmp/diag_montage.jpg 是对比图, 终端会打印 Y/Cb/Cr 统计
```

### 10.4 顺带说明：另外两个"看起来像颜色问题"的现象

| 现象 | 其实是什么 | 去哪改 |
|------|-----------|--------|
| 画面整体发白/过曝 | **IMX415 曝光/增益偏高**，和色彩解析无关（修完颜色后仍然过曝，就说明是这个问题） | FPGA：`ui_imx415_cfg/ui_imx415_reg.v`（曝光/增益初值）、`ui_ae_set`（AE 档位） |
| 边缘有紫/青色描边 | 色度与亮度对齐偏差（YUV422 打包）| FPGA：`csi2_pack_yuv422_stream.v` |

---

## 11. 帧率优化（2026-10，同画质下 9.3 → 22.1 fps）

### 11.1 先量一下瓶颈在哪

`bench_stages.py`（逐阶段计时）：

| 阶段 | 优化前 |
|------|--------|
| `cap.read()` 读原始 NV16 1080p | 25.3 ms |
| `yuv_to_bgr()` 转换到 720p | **53.7 ms ← 主要瓶颈** |
| `cv2.imencode()` JPEG q80 720p | 8.1 ms |
| **合计** | **≈ 88 ms → 11 fps** |

再拆 `yuv_to_bgr` 内部：

| 子步骤 | 耗时 |
|--------|------|
| YUV 域 resize（uint8，`cv2.resize`） | 8.2 ms |
| `astype(float32)` + 量程缩放 | 4.8 ms |
| **矩阵运算 + 裁剪 + 落 uint8（numpy）** | **45.0 ms ← 元凶** |

### 11.2 改动一：矩阵运算换成 int16 查找表（数值不变）

numpy 在 720p 上做浮点广播加法 + `np.clip` + `np.rint` 会被内存带宽拖死。
改成：

- 把「limited→full 量程展开」与「BT.709 矩阵系数」**合并预计算成 256 项 int16 查找表**；
- 查表用 **`cv2.LUT`（SIMD）**，绝不用 numpy 花式索引（`lut[u8]` 慢十几倍）；
- 全程整数运算，去掉 `np.rint` 那一遍；
- 原地裁剪 + 写进预分配缓冲，去掉 `np.stack` 的大临时数组。

```
优化前 float32 版 : 53.7 ms
优化后 int16 版   : 29.8 ms      (快 1.77 倍)
数值一致性: 最大绝对差 = 1 LSB, >1LSB 的比例 = 0.000%
```

> 曾经尝试过的"更快"方案 —— `cv2.cvtColor(COLOR_YUV2BGR_YUYV)` + `cv2.transform`
> 修正 601→709（只要 4.5 ms），但实测与手写实现有 **82% 的像素差 >8、最大差 31**，
> 不是等价转换，因此**放弃**。速度再快也不能换画质。

### 11.3 改动二：修掉限帧逻辑的 bug（这一条贡献最大）

原代码：

```python
dt = 1.0 / target
time.sleep(max(0.0, dt - 0.004))     # ← 错：固定睡掉一整个帧周期
```

它把每帧的处理耗时又重复算了一遍，等于每帧白等 ~36 ms，
**把本来能跑 22 fps 硬压到 12 fps**。改成只补足"剩余时间"：

```python
rest = dt - (time.time() - t_start)   # t_start 在本轮循环开头
if rest > 0.0005:
    time.sleep(rest)
```

### 11.4 实测结果

| 版本 | 帧率 |
|------|------|
| 优化前（float32 + 限帧 bug） | 9.3 fps |
| 只换 int16 查表 | 12.1 fps |
| 再修限帧 | **22.1 fps** |

分辨率、格式、色彩解析（BT.709 + limited）、JPEG 质量全部未变，
逐像素与优化前**最大差 1 LSB**，即真正意义上的同画质。

### 11.5 还想再快？

1. **降推流分辨率**（会有画质差异）：`--stream-width 960`，预计 ~28 fps。
2. **`--backend gstlive`**（原生 GStreamer，`videoscale + jpegenc` 全 SIMD）：
   实测整条管线 **37.4 fps**，且 `videobalance/gamma/videoflip` 在线调参也没问题。
   **代价**：本机 GStreamer 的 `videoconvert` 不做 16-235→0-255 展开
   （`capssetter` 重新标注 colorimetry 完全无效，试过所有写法），
   所以要么接受偏灰，要么用 `videobalance` 近似补偿（矩阵仍是 601）。
   追求"绝对同画质"就用默认的 `opencv` 后端。
   ```bash
   PYTHON=python3 ./start_webstream.sh /dev/video22 9012 --backend gstlive
   ```
   （`gstlive` 需要 `gi`，只有系统 `python3` 有；`mlk-ov` 环境没有）

### 11.6 复现用的基准脚本

```bash
pkill -f 'mipi_web[s]tream'
/opt/miniforge3/envs/mlk-ov/bin/python bench_stages.py /dev/video22   # 逐阶段计时
/opt/miniforge3/envs/mlk-ov/bin/python bench_new.py   /dev/video22   # 优化前后对比
./gst_tune_test.sh /dev/video22                                       # 原生管线吞吐
```

