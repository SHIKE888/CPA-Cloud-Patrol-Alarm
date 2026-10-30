# V54 全链仿真记录（2026-10-30）

> 每个台架的判据都是**可机检的硬数字**，不是"看起来没问题"。

---

## 1. 台架清单

| 台架 | 覆盖范围 | 运行 |
|---|---|---|
| `tb_dual_stitch.v` | 双路异步时钟 → 拼接（顺序/行宽/tuser/tlast/掉一路） | `run_dual_stitch.ps1` |
| `tb_preproc.v` / `tb_basic.v` / `tb_he_*` | 预处理内部算子 | 各自的 ps1 |
| **`tb_pre2jpeg.v`（新）** | **preproc_post → rgb_to_yuv422_quad → 4 引擎 → 段合并 → 桥 → CSI-2** | `run_pre2jpeg.ps1` |
| `tb_wd.v` | dbuf 读侧 → 4 引擎 → 段合并 → 桥 → CSI-2，**带板上那套看门狗** | `run_tb_wd.ps1` |
| **`tb_wd_full.v`（新）** | 同上，但宽度/行数可参数化到 3840×1080 | `run_tb_wd_full.ps1` |

---

## 2. tb_wd 512×32 基线（V53c 修复的判据）

```
MERGED  : 6007 bytes  segcnt=19  cyc=54338
WORDS   : 4096 (exp 4096)   SOF=1 (exp 1)   LAST=32 (exp 32)
ERR  px=0 last=0 sof=0 grp=0
ENG by  : 1303/1394/1303/1392   wl=1024   ovf=0
BRIDGE  : level=0  wbp=0
PIXEL PATH  OK
```

`6007` 与 `fpga/sim/base6007.jpg` **逐字节相同**（`verify_jpeg.py` 复核：SOF0 512×32，
3 分量，熵数据 5392 B）。这条就是 V53b 那个 `S_mrg_start` 修复成立的证据。

---

## 3. 台架自身的坑（这次踩到的，写下来省下次）

1. **`tb_wd.v` 的 `W4` 是硬编码 `localparam integer W4 = 128`**，不是 `W1/4`。
   生成 3840 宽的台架时只改 `W1`/`H`，就会变成"源发 3840、分组与逐字比对按 128"——
   现象是 `[ERR-E32]` 满屏 + 引擎"少吃 10% 数据"，**看起来像 RTL 卡死，其实是台架错**。
   ⇒ `gen_tb_wd_full.ps1` 已把它改成 `parameter integer W4 = W1/4`。

2. 每引擎 32b word 数 = `(W1/4)*H/2 = W1*H/8`，不是 `W1*H/16`。
   `x_wl` 是 64b word 计数、`n_rd32` 是 32b word 计数，**两者差 2 倍，别混用**。

3. `m_segc` 只有 10 位；段数 = `(H/RSTI)*4 + 3`（H=32/RSTI=8 时是 19，不是 4*H）。

4. **`Tee-Object` 记日志会把 vvp 拖慢约 100 倍**，必须 `& vvp x.vvp *> log`。
   而重定向到文件时 `$display` 是块缓冲（8 KB 才刷），**日志 0 字节不代表没在跑**。

5. iverilog 14 的 `-P` 必须写成 `-P tb.param=val`（**空格分隔**）；`-Pxxx` 会被当成文件名。

6. 仿真速度约 **220 拍/秒**（4 个 JPEG 引擎的模型太重），
   3840×1080 一帧 1.22 M 拍 ⇒ 约 90 分钟。别指望它"跑一下就好"。

7. `fpga/sim/` 里的 **`tb_wd_base.v` / `tb_wd_seg.v` / `tb_jpeg_full.v` 是历史版本**，
   它们引用了 V54 里**已被回退掉**的端口（`m_seg_end` / `i_seg_end` / bitpack 内部的
   `push_ok` / `em_v`），现在**编译不过**。可复用的只有 `tb_wd.v` 和 `tb_wd_full.v`。

---

## 4. 结果

（`tb_pre2jpeg` 与 `tb_wd_full` 的结果见下方，按实际运行填写）

### 4.1 tb_pre2jpeg（512×32，73.75 MHz 单时钟）

判据：
- `ERR yuv=0 user=0 last=0` —— rgb2yuv 输出与台架内定点参考模型**逐字节相同**
- `segcnt = (H/RSTI)*4+3 = 19`
- `ovf = 0`
- `pre2jpeg.jpg` 通过 `verify_jpeg.py`

### 4.2 tb_wd_full（3840×32 / 3840×1080）

判据：
- `PIXEL PATH OK`（逐像素 0 错）
- 每引擎 `n_rd32 = W1*H/8`
- `ovf = 0`，无 `TIMEOUT`
- `verify_jpeg.py full.jpg --w 3840 --h 32`

**3840×32 实测（PASS）**：

```
WORDS   : 30720  (exp 30720)          <- 源把整帧 3840x32 全送出了
ERR  px=0 last=0 sof=0 grp=0          <- 逐像素/行尾/帧首/每行组数 全 0 错
MERGED  : 41049 bytes  segcnt=123     <- (32/8)*(960/16)*(32/8)/8*4+3 = 123 段
ENG by  : 10059/10110/10097/10168  wl=7680/7680/7680/7680  ovf=0
BRIDGE  : level=0  wbp=0
PIXEL PATH  OK
```

`wl=7680` = 32 行 × 240 word/行，**四个引擎都吃满** ⇒ 3840 宽的行内 1/4 分组
（`S_jg_vld` 的 240/480/720 门限）在真实宽度下是对的。

`verify_jpeg.py full.jpg --w 3840 --h 32`：
```
SOF0 3840x32 ncomp=3 prec=8
ENTROPY 40434 B (98.5%)
TOTAL   41049 bytes
RESULT  PASS
```

### 4.3 ★ 本版修掉的一个真 bug：`rgb_to_yuv422_quad` 控制链比数据链晚一拍

`tb_pre2jpeg` 第一次跑就报了 3 万多条 `[ERR-Y]/[ERR-B]/[ERR-C]`，
现象是**实际数据比期望超前 4 个像素**（第 k 个 `o_de` 读到的是第 k+1 组）。

根因：
```
数据链: pr -> m_* -> s_* -> yv/cb/cr -> o_data   共 4 拍
控制链: i_de -> de_d[0..3] -> o_de               共 5 拍   <- 多了一拍
```
而 `system_top.v` 里 `S_ud_wtvalid = S_yuv_de`、`S_ud_wtdata = S_yuv_data`
⇒ **dbuf 每行丢掉第一组 4 像素**，其余整体左移 4 像素，行尾多写一组越界数据，
`tlast` 也跟着错一拍。

4/3840 = 0.1%，肉眼完全看不出来，所以从 V20 起一直没被发现。
修法：`o_de/o_user_sof/o_last` 改用 `de_d[2]/sof_d[2]/last_d[2]`，与 `o_data` 同拍。
