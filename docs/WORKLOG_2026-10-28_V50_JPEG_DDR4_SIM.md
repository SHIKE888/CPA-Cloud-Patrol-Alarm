# 2026-10-28 V50：JPEG 源改到 DDR 读侧 + 四引擎，全链路仿真通过

## 结论（一句话）

`tb_jpeg_ddr4`（dbuf 读侧 → yuv32_to_quad → 行内 1/4 分组 → 4×jpeg_enc_if → 4×编码器 → seg_merge4）
输出与基准 `merged4.jpg` **逐字节完全一致（6007 B，零差异）**，像素通路零错误。

```
WORDS   : 4096  (exp 4096)
SOF     : 1     (exp 1)
LAST    : 32    (exp 32)
ERR  px=0 last=0 sof=0 grp=0
MERGED  : 6007 bytes  segcnt=19
ENG by  : 1303/1394/1303/1392   wl=1024/1024/1024/1024   ovf=0
PIXEL PATH  OK
ddr4.jpg == merged4.jpg  (byte-identical, 6007 B)
```

引擎字节数 1303/1394/1303/1392 与基准 `tb_jpeg_merge4` 的 `e0/e1/e2/e3` **完全相同**，
说明四引擎在 DDR 读侧源下产出的码流与"直连送数"路径完全等价。

---

## 本轮抓出并修掉的 6 个 bug

| # | 文件 | 缺陷 | 后果 |
|---|---|---|---|
| 1 | `yuv32_to_quad.v` | FIFO `rd_en` 端口接成 `c_ready & ~f_empty` | 门控一开读指针每拍自增，一半数据被跳过，`d_v/h_v` 对齐逻辑完全旁路 |
| 2 | `yuv32_to_quad.v` | `put_data = {…, low32, r_data}` | 半字顺序反了（晚像素在低半），与 `jpeg_enc_if` 契约相反 |
| 3 | `system_top.v` | `jpeg_enc_if.s_sof` 接写侧 `S_yuv_sof` | 读侧源配写侧帧首，帧同步错 |
| 4 | `system_top.v` | `S_jg_gcnt` 只用 `S_jcfg_valid` 计数 | gate=0 时 `c_valid` 常高，分组边界被冲飞 |
| 5 | `system_top.v` | `s_valid` 未带 `S_enc_gate_r` | 门控关闭期间同一个 word 被重复写进 FIFO |
| 6 | `jpeg_encoder_top.v` | `jpeg_enc_if` 无起送门限 | **致命**：见下 |

## 最重要的一条：jpeg_encoder_top 不能容忍 s_valid 断流

`tb_eng_eif` 最小复现（单引擎 + enc_if，数据与整合测试逐字节相同）：

| 送数方式 | 结果 |
|---|---|
| 连续背靠背 | `wl=1024/1024` 全部吃完，帧字节 1319 ✅ |
| 突发（每行 32 word + 空 3/4 行） | `wl=768` 卡死，`o_seg_done` 永不置位，熵编码器持续吐垃圾（~1 B/clk，45063 B）❌ |

原因：编码器行缓冲一次要**预取 8 行**；预取途中断粮会永久卡死。

门限扫描（每引擎每行 32 word 的小尺寸）：

| START_LEVEL | 结果 |
|---|---|
| 192 (6 行) | FAIL |
| 224 (7 行) | PASS |
| 256 / 288 / 320 / 960 | PASS |

→ **缓冲必须 ≥ 约 7 行**。真实设计每引擎每行 240 word，故需 ≥1680，最终取
`AW=11`（2048 深）+ `START_LEVEL=1920`（8 行）。

`jpeg_enc_if` 新增参数 `START_LEVEL`，默认 0 = 旧行为，不影响任何既有例化。

## 资源影响（需综合确认）

`enc_if` FIFO 由 1024×65b 增至 2048×65b：

```
4 × 2048 × 65 bit = 66.5 KB  ≈ 60 个 ERAM
```

当前 phy 后 ERAM 已用 204/272（75%），余 68 → 预计落到约 **264/272（97%）**。
DSP 不受影响（仍 240/240）。若 ERAM 布线失败，回退顺序：
1. `START_LEVEL` 降到 1680；
2. 若还不够，需重新评估"4 引擎 + 行内 1/4 复用"这一架构。

## 新增/修改文件

- 新增 `fpga/uisrc/01_rtl/jpeg/yuv32_to_quad.v`（32b/2px@147.5MHz → 64b/4px@70MHz）
- 新增 `fpga/uisrc/01_rtl/jpeg/jpeg_seg_merge4.v`（1/4 行段 4:1 合并）
- 修改 `jpeg_encoder_top.v`：`jpeg_enc_if` 加 `START_LEVEL` 起送门限
- 修改 `system_top.v`：V49/V50 四处修复 + `AW(11)/START_LEVEL(1920)`
- 新增仿真 `tb_conv1.v` / `tb_eif1.v` / `tb_eng_eif.v` / `tb_jpeg_ddr4.v`

## 复现命令

```powershell
cd fpga/sim
# 32->64 拼装
iverilog -g2005 -I ../uisrc/01_rtl/jpeg -o tb_conv1.vvp tb_conv1.v `
  ../uisrc/01_rtl/jpeg/yuv32_to_quad.v ../uisrc/03_ip/al_fifo/fifo_32b_async_2.v
vvp tb_conv1.vvp          # -> CONV1 PASS

# 64b -> 2x32b 拆分
iverilog -g2005 -I ../uisrc/01_rtl/jpeg -o tb_eif1.vvp tb_eif1.v @(文件清单)
vvp tb_eif1.vvp           # -> EIF1 PASS

# 全链路（当前主验收）
powershell -File .\run_jpeg_ddr4.ps1
# -> PIXEL PATH OK / MERGED 6007 B / ddr4.jpg 与 merged4.jpg 逐字节一致
```

## 仍需处理

1. 综合 + 布线：确认 ERAM ≤272、DSP =240、`S_clk_70m` Fmax ≥70 MHz
2. 板测：`0xA0~0xA2`（编码字节数）必须 >0；`/api/sys` 的 `direct_frames` / `fps`
3. IOMMU page fault（300 次）仍未解决 —— 是屏蔽 `CSI_SIZE_ERR` 的副作用
4. 画质指标（Q/4:2:2）尚未测过
