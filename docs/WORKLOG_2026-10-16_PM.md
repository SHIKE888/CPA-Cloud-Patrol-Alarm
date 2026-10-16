# 2026-10-16 工作日志（下午/晚间）

## 一句话结果

**4K25 第一次成功出图了。** 但也暴露两个新问题：画面有 ~1% 脉冲噪声、严重过曝；
根因线索指向 **FPGA 时序不收敛**（clk4 像素域 setup 违例 5.19 ns）。

---

## 1. 今天的重大突破链

| # | 发现 | 处置 |
|---|---|---|
| 1 | 手册 P48「Readout Drive mode」有 **9 个链路速率档**；1080p(binning) 用 `SYS_MODE=5`=891 Mbps，而厂商 4K 表用 `SYS_MODE=8`=1440/1485 Mbps | V27：4K 也改用 **891 Mbps**（与 1080p 同档），D-PHY 无需变速、无 deskew burst |
| 2 | `STANDBY(0x3000)` 手册是 `0=Operating, 1=Standby` | 回退 V26 的极性误改 |
| 3 | 内核 `rkcif_create_dummy_buf()` 用 `enum_frame_interval` 轮询 sensor 报的尺寸算 dummy buffer 大小；我们的驱动把它当"过滤器"用，`width==0` 时返回 -EINVAL | 改成真正的枚举器 → `Cannot allocate memory` 消失 |
| 4 | `csi2_pack_yuv422_stream` 输出 FIFO 流量门限写死 `1900`（按 1080p 的 960 word/行 定的），4K 一行是 1920 word | V28：FIFO 2048→4096，门限 1900→3840 |

## 2. 板上验证结果（V28，bit 2026-10-16 19:47:40）

```
FPGA:  0xE0(RES_MODE)=2, 0xD4/0xD5 = 0x03C6 = 966 组/行  (= all-pixel 4K)
RK  :  dphy3 data_rate_mbps 1000,  抓帧 49766400 字节 = 3.00 帧 x 3840x2160x2  精确!!
图像:  真实场景, 几何正确
```

**几何判定（工具 `tools/analyze_y.py`）**

| 项 | 实测 | 结论 |
|---|---|---|
| 逐行水平平移 | dx 在 ±5 随机跳，相邻行平均差 2.7~7.6 | 无系统性行错位 ✓ |
| 行内自相关 lag=960/1919/1920 | 14.7~18.0（lag=1 只有 3.2）| 无半宽复制/镜像 ✓ |
| **脉冲噪声率** | **1.08%** | ❌ 约 1% 孤立像素错 |
| 亮度分布 | 192~223 占 66% | 严重过曝/低对比 |

## 3. 新问题：时序不收敛

`fpga/fpga_prj_Runs/phy_1/final_timing.rpt`（V28 构建）：

```
STA coverage: 31.93%
SWNS: -5.186ns, STNS: -728.154ns      <- setup 违例
HWNS: -2.305ns, HTNS:  -27.489ns      <- hold  违例

clk4  147.514MHz (S_pclkx1 像素/VTC 域, 含 u_csi2_pack)  SWNS=-5.186  STNS=-305
clk0  133.333MHz (X_ui_ddr/dfi_clk)                      SWNS=-3.355  STNS=-356
clk2  125.000MHz (S_dsi_byte)                            SWNS=-1.621  STNS=-13
clk3   25.000MHz (sys_clk)                               HWNS=-2.305
```

`clk4` 周期 6.779 ns，实际路径 11.97 ns（超 77%）。

**推断**：1% 脉冲噪声来自这些违例路径（数据相关毛刺/亚稳态）。
**可能性**：1080p 时画面干净，说明违例路径大概率在 **4K 才被激活的路径**上
（4K 下 `u_csi2_pack` 的 12bit 比较器 + FIFO 变深后的长组合链）。

## 4. 下一步候选（待定优先级）

1. **补全 SDC 约束**（当前只有 32% 覆盖）+ 时序优化，让 clk4/clk0/clk2 收敛
   —— 这是消除 1% 噪声最可能的正解。
2. **排查 RX 侧偶发错字**：4K 与 1080p 同为 891 Mbps，但 4K 行更宽、行率不同；
   可在 FPGA 里加 RX 侧错误计数（CRC/sync 丢失）取证。
3. **过曝**：调曝光/增益（FPGA 侧 `ui_imx415_reg.v` / `cam_param.v`）。
4. 4K 画面达标后再做：Web 侧 4K 打通、`MODE_SWITCH_SAFE=True`、`FPS_DIV` 跳帧。

## 5. 本次新增工具

| 工具 | 用途 |
|---|---|
| `tools/raw_y_to_png.py` | 裸 Y 平面 → PNG（纯 Python，无 PIL/numpy）；支持 step/offset 抽交错格式 |
| `tools/analyze_y.py` | 量化画面缺陷：逐行平移 / 脉冲噪声率 / 行内自相关 / 亮度分布 |
| `tools/pdf_imx415.py` | IMX415 数据手册文本提取（dump / find）|
| `tools/pdf_pages.py` | 手册指定页渲染成 PNG（看多列表格）|
| `tools/vm_build_v27.sh` | VM 上覆盖驱动 + 增量编译内核 + 备份 |
| `rk/deploy/check_4k_v27*.sh` | 分段上板验证 |
| `rk/deploy/verify_4k_v28.sh` | V28 4K 抓帧验收 |
| `rk/deploy/grab_4k_png.sh` | 4K 取证（统计 + 转 PNG）|

## 6. 关键环境事实（复用）

- TD 工程 `08_csi2rk_mipi_imx415/fpga/fpga_prj.al`，其 `.prj` **直接引用**
  `../../uisrc/...`，改 `fpga/uisrc/` 就是改工程，**无需同步**
- 内核驱动是**内置** `=y`，在 `<SDK>/kernel-6.1/drivers/media/i2c/milianke_mipi.c`
- 增量编译内核：`make -C $SDK/kernel/ -j17 CROSS_COMPILE=... ARCH=arm64 mlk-afh03-rk3576-linux.img`（22 秒）
- 板上回滚镜像：`/root/boot.before-v27.img`（md5 `7de2852e…`，内核 `#7`）
- VM 内核备份：`/home/uisrc/kernel-backup/20261016-192807-v27/`
