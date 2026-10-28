# 变长 CSI-2 帧接收 JPEG 码流（2026-10-28）

## 背景：为什么必须做变长帧

赛题硬指标是 **1080p@60fps 双目 + FPGA 硬件 JPEG 压缩**（见 `作品方向.TXT`），
而 60 fps 的时间预算已经被编码器本身吃满：

| 项 | 数值 |
|---|---|
| 16200 MCU × 151.3 clk @ 147.5 MHz | **16.62 ms** |
| 60 fps 预算 | 16.67 ms |
| 剩余 | **0.05 ms** |
| 补零速率（1 字节/拍 @ 147.5 MHz） | 147.5 MB/s |
| ⇒ 余量最多补 | **7 KB** |

定长帧（`0x0B[2]=1` 补零到 3840×1080×2 = 8,294,400 字节）需要的补零量是
8 MB 量级，物理上不可能挤进 0.05 ms。实测 70 MHz 下补零一帧要 118 ms
（≈8.5 fps），147.5 MHz 也只有 56 ms（≈18 fps）。

所以 **变长帧不是优化项，是 60 fps 的前置条件**。

## 已排除的路径

| 路径 | 结论 |
|---|---|
| PCIe bulk 传码流 | 本板 PCIe 不可用，排除 |
| rkcif 原生 JPEG 支持 | `CIF_FMT_TYPE` 只有 YUV/RAW；`V4L2_PIX_FMT_JPEG/MJPEG` 在整个 `drivers/media/platform/rockchip` 零命中；`INPUT_MODE_JPEG` 定义了但 0 处使用；`capture.c:6522` 自己写着 `JPEG, TODO`。不可行 |
| rkisp / ispp | 同样无 JPEG 格式 |
| 拆成多个小定长帧让应用层拼 | 要把浪费压到 7 KB 需子帧 ≤ 7680 字节，250 KB 码流要拆 33 段 → 2000 fps 的 V4L2 帧率，不现实 |
| RK 侧 VPU 硬编 | 3840×1080 单帧 op 约 14.6 ms，两路超预算 |

## 采用的方案：把 JPEG 当作 YUV422 字节流运输

CSI-2 上仍按 **DT 0x1e (YUV422)** 传输，只是**内容**是 JPEG 字节流。
RK 侧不解析，应用层直接从 vb2 buffer 里扫 `FF D8 ... FF D9`。

两端代码本来就都就绪：

- FPGA：`system_top.v` 的 `JLS_*` 状态机在 `S_jpeg_pad=0` 时走
  `else if (S_jb_l) S_jl_cnt <= 0;` —— **短帧直通，帧在编码器输出结束时立即收尾**
- RK：`rk/web/mipi_webstream.py` 的 `_jpeg_in_frame()` + `_publish_direct()`
  已实现零重编码发布

## 内核唯一的改动

`drivers/media/platform/rockchip/cif/capture.c`，把 `CSI_SIZE_ERR` 从 INTEN 里抠掉。

原来的行为（`capture.c:14148`）：

```c
if (intstat & CSI_SIZE_ERR) {
        ...
        cif_dev->irq_stats.csi_size_err_cnt++;
        cif_dev->err_state |= RKCIF_ERR_SIZE;
        ...
        rkcif_write_register_or(cif_dev, CIF_REG_MIPI_LVDS_CTRL, 0x000A0000); /* CSI host 软复位 */
        return;   /* 同一轮里的 FRAME_END 被跳过 → 帧被丢 */
}
```

后面还有第二道：

```c
if (intstat & CSI_ALL_ERROR_INTEN_V1) { all_err_cnt++; return; }
```

而 `CSI_SIZE_ERR` 是 `CSI_ALL_ERROR_INTEN_V1` 的子集
（`regs.h:1041` `#define CSI_ALL_ERROR_INTEN_V1 (0xf0f << 16)`，SIZE_ERR 占 bit 24-27），
所以只改第一处 `return` 没用。

改法：

```c
rkcif_write_register_or(dev, CIF_REG_MIPI_LVDS_INTEN,
                        CSI_ALL_ERROR_INTEN_V1 & ~CSI_SIZE_ERR);
```

`FRAME_END` 由 CSI-2 的 FE 短包触发，与字节数无关，所以短帧依然会正常完成。
其它错误中断全部保留。

补丁见 `rk/driver/kernel-patches/0001-cif-allow-variable-length-csi2-frames.patch`。

## 已知副作用

buffer 里实际载荷之后的字节是**上一帧残留**（不是清零）。消费端必须自己
定位载荷长度（扫 `FF D8` 起、第一个 `FF D9` 止）。`_jpeg_in_frame()` 就是这么做的：
它甚至要求 `buf[0]==0xFF && buf[1]==0xD8`，也就是 JPEG 必须从 buffer 第 0 字节开始。

## 验证顺序

1. 内核替换（已完成，见下"实施记录"）
2. FPGA 烧 `0x4712`（DROP 死锁修复版），`0x0B = 0x01`（tx=1, dt18=0, pad=0）
3. 看 `/dev/video22` 是否出帧 —— 这一步验证"短帧能不能完成"
4. `/api/sys` 的 `direct_frames` 应当开始增长，`fps` 应从 3.5 跳上去
5. 抓一帧验证画质

## 实施记录

| 步骤 | 状态 |
|---|---|
| 内核补丁 | ✅ 已打，增量编译 24 s，烧入 boot 分区，MD5 `fa1d9d0c28dbe475676a74e35317a353` 读回一致 |
| 板子重启 | ✅ 14 s 起来，`6.1.99`，rkcif 正常 probe |
| FPGA `0x4712` | ⏳ 布线进行中（`phy_1`） |
| 板上验证 | ⏳ 待 FPGA |

### 当前板上的 bit 是 0x4711，不是 0x4712

读 `0xA9/0xAA` 得 18193 = **0x4711**。也就是说 DROP 死锁还没修，而板上实测
`0xEF` 低两位恒为 `2` = `JLS_DROP`，正好卡在那个构造性死锁上。
必须换成 `0x4712` 才能往下测。

### 备份

- 内核原文件：VM `cif/capture.c.bak_varlen`
- boot 分区：板子 `/root/boot_backup_varlen_20260427_210938.img`（47 MB，45 MiB）
  以及更早的 `/root/boot_backup_20260427_200058.img`（64 MB 全分区）
