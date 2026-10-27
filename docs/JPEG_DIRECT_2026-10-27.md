# JPEG 直通：RK 端零解码零重编码（FPGA `0x470A`）

日期：2026-10-27 · 分支 `feature/dual-front-stitch`

## 1. 为什么做

赛题要求"传给 RK 的必须是 JPEG 压缩流"。原实现走的是：

```
FPGA (NV16 原始像素 4.1MB/帧) ──CSI-2 DT=0x1E──► rkcif ──► /dev/video22
        │
        └─(另一路) FPGA 硬件 JPEG ──DT=0x18──► 被 rkcif 拒收（没人用）
                                                    │
RK 侧：cv2 解码 NV16 → BGR → cv2.imencode JPEG（或 mppjpegenc）──► 浏览器
```

RK 侧那一步重编码是纯浪费，而且**就是延时的来源**。实测（`tools/board_jpeg_latency_ab.py`，1080p）：

| 动作 | 耗时 |
|---|---|
| NV16→NV12 + tobytes（`_nv12_scaled`） | 2.5 ms |
| `cv2.imencode` Q49 / Q75（单线程） | 21.6 / 22.7 ms |
| `mppjpegenc` 一进一出往返（写 3.1MB 管道→VPU→读回） | 24.3 ms |
| `mppjpegenc` 深灌 5 帧的每帧成本（纯 VPU） | **14.6 ms** |

- 软编靠 **3 个线程并行**才跟得上 60fps；
- 硬编塞在 `_conv_loop` 里**单线程串行**（2.5+24.3 = 26.8ms/帧 → 37fps < 60fps 源）；
- `_put()` 是**阻塞背压**，跟不上就堵采集线程 → 再堵 V4L2 vb2 队列（≈4 帧）
  ⇒ 额外 (3+4)×16.7 ≈ 100ms 延时。这就是"开硬编反而更延时"的机理。

## 2. DT=0x18 为什么不行（板上实测）

```
i2cset 0x0B 1        # 让 MIPI 发 JPEG 码流（DT=0x18）
dmesg:
  (0x27cb0000)MIPI_CSI2 ERR2:0x10001100 (ecc,vc: 0) (err id,vc: 0)
  (0x27cb0000)MIPI_CSI2 ERR1:0x1000000 (crc,vc: 0)
  ... 抓 8 帧 → 0 字节
```

CSI-RX 是按 sensor subdev 的 `YUYV8_2X8` 配的（期望 DT=0x1E），收到 0x18 直接
`err id` 丢弃。要让 0x18 生效得改 rkcif / 驱动侧，属于内核改动。

## 3. 最终方案：借用 DT=0x1E，把 JPEG 当"像素"发

rkcif 本质是 DMA：收到多少字节就往帧缓冲写多少。所以只要 **DT 对得上**，
把编码器码流当成像素数据发过去，收端照样能拿到帧 —— 帧缓冲前段就是完整 JPEG。

FPGA 侧（`0x470A`）：

| 寄存器 | 位 | 含义 |
|---|---|---|
| `0x0B` | bit0 | `JPG_TX`：1 = MIPI 发 FPGA 硬件 JPEG 码流（0=原 NV16 直通） |
| `0x0B` | bit1 | `DT18`：0 = 长包 DT **0x1E**（rkcif 当前唯一认的）　1 = 0x18（标准 JPEG） |
| `0x0B` | bit2 | `JPAD`：1 = 帧尾补 0 到整帧 4147200B（默认，最稳妥）　0 = 短帧（省带宽，待验证） |

- `csi2_frame_tx_var` 的 `DT` 从编译期参数改成**运行时端口** `i_dt`；
- 新增补零/截断小状态机（`JLS_DATA/PAD/DROP`，组合输出、跟着 `s_tready` 走）：
  - 编码器 `m_last` 之后补 0 直到 4147200 B（`JPAD=1`）；
  - 帧字节数超过整帧时**截断并吞掉本帧剩余**（0x4708 出现过 4694772 > 4147200）。

RK 侧（`rk/web/mipi_webstream.py`）：

- `_jpeg_in_frame(frame)`：帧首是 `FF D8` 就认为进了直通模式，`find(b"\xff\xd9")` 取整帧
  （熵编码里的 `FF` 都做了 `00` 填充，第一个 `FF D9` 就是 EOI）；
- 参数全默认 + 单目 + 没开 AI ⇒ `_publish_direct()` **直接把那几十 KB 推给浏览器**，
  连 `_raw_q/_bgr_q` 都不进，编解码线程空转（CPU 占用趋近 0）；
- 需要逐像素处理（缩放/几何/亮度/AI 叠加）时才 `cv2.imdecode` 一次走老路；
- ⚠ 直通发布必须把 `_next_pub` 推过本帧序号：`_results/_next_pub` 和 `_enc_loop` 共用，
  否则回到队列通路时 `_next_pub` 卡在旧序号，推流永久卡死（已加注释）；
- `/api/sys` 的 `mipi` 块新增 `jpeg_direct / direct_frames / direct_bad`，
  网页链路格显示 `直通` 后缀。

## 4. 验证步骤

```bash
# 1) 烧 0x470A 后确认版本
i2cget -y 9 0x40 0xA9; i2cget -y 9 0x40 0xAA     # 09 / 47

# 2) 开直通（两条通路互斥，先切 MIPI 源）
i2cset -y 9 0x40 0x0B 5      # bit0=1 JPEG, bit1=0 (DT 0x1E), bit2=1 (补满整帧)
i2cget -y 9 0x40 0x0B        # 应为 0x05

# 3) 看服务
systemctl restart mipi-webstream
curl -s http://127.0.0.1:9012/api/sys | python3 -m json.tool | grep -E 'jpeg_direct|fps|latency'

# 4) 逐位 A/B：bit1=1（DT 0x18）预期 0 帧 + dmesg err id；
#    bit2=0（短帧）看 rkcif 能不能交出不完整帧
```

期望：`jpeg_direct: true`、`fps` 接近 59、`latency_ms.capture_to_ready` 只剩 5~10ms 量级。

## 5. 回退

`i2cset -y 9 0x40 0x0B 0` → MIPI 回到原 NV16 通路，web 端自动检测到帧首不是 `FF D8`，
无缝回到"解码 + 重编码"老路（无需重启服务）。
