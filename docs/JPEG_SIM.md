# JPEG 支路仿真说明（怎么跑、每个台验什么）

环境：iverilog（oss-cad-suite）
```powershell
$s="$env:USERPROFILE\oss-cad-suite"; $env:PATH="$s\bin;$s\lib;"+$env:PATH; $env:YOSYSHQ_ROOT=$s
```

## 1. 字节级端到端回归（最重要）

```powershell
# 默认尺寸集（很慢，1920x216 要几分钟）
.\tools\run_jpeg_sim.ps1
# 快速子集
.\tools\run_jpeg_sim.ps1 -Sizes @("64x16","320x40","1920x48")
```
每个尺寸：`gen_jpeg_e2e.py W H` 生成 `fpga/sim/jpeg_in.hex`（YUV422 输入）
和 `ref.jpg`（`tools/jpeg_ref.py` Python 参考编码器的输出），
然后 `tb_jpeg_e2e.v` 跑 RTL，`cmp_jpeg.py` 做**逐字节**比对。

判据只有一条：`IDENTICAL`。长度相同但内容不同＝FAIL。

> ★ 仿真台里 qtable 必须接 `O_rd_data_a_asyn`（异步口）。
> 生产代码 `system_top` 用的就是异步口；接成寄存器口 `O_rd_data_a`（滞后 1 拍）
> 会让 DQT 头第一个 Q 值被复制成两字节，看起来像"编码器 DQT 有 bug"。

## 2. 吞吐（clk/MCU）与物理结论

```powershell
cd fpga\sim
.\run_jpeg_thru.ps1 0     # 有损
.\run_jpeg_thru.ps1 1     # 无损
```
打印 `clk/MCU`、以及"跑到 248.8 Mpx/s（= 双1080p60 = 4K30）需要多少 MHz"。
输入是自增计数器（不关心画质），只测吞吐。

## 3. 输入接口 / 跨时钟桥

```powershell
cd fpga\sim
.\run_jpeg_enc_if.ps1        # 64bit 4px/拍 -> 2px/拍, 逐字比对 + 溢出检测
.\run_jpeg_byte_bridge.ps1   # 编码器域 -> 发送域 字节级不丢
```

## 4. 全链路（JPEG -> CSI-2 变长包 -> 解包）

`tb_jpeg_csi2_e2e.v`：**当前未绿**（`FS=18/FE=14`、payload 只有 520 字节）。
`csi2_frame_tx_var` 的帧边界行为要连发送侧一起重做，重做后本台重写。

编译方式（注意要带 `csi2_frame_tx.v` 和异步 FIFO）：
```powershell
iverilog -g2005 -o tb_csi2.vvp -I ../uisrc/01_rtl/jpeg -I . tb_jpeg_csi2_e2e.v `
    (Get-ChildItem ../uisrc/01_rtl/jpeg/*.v | % { $_.FullName }) `
    ../uisrc/01_rtl/csi2_frame_tx.v ../uisrc/03_ip/al_fifo/fifo_32b_async_2.v
vvp tb_csi2.vvp
```

## 5. 其它辅助台

| 文件 | 用途 |
|---|---|
| `tb_jpeg_dct.v` | 2D DCT 单元级 |
| `tb_jpeg_ll.v` | 无损 DPCM 单元级 |
| `tb_he_big.v` | 直方图均衡（与 JPEG 无关，历史遗留） |

## 6. 已知坑

1. **文件清单别手写**：`run_jpeg_sim.ps1` 曾漏 `fifo_32b_async_2.v` 和
   `jpeg_lossless_enc.v`，报 `Unknown module type`。现在用 `Get-ChildItem *.v` 自动收集。
2. `jpeg_encoder_top.v` 里**内联**了 `jpeg_enc_if` 和 `jpeg_byte_bridge`，
   所以编译它必须带异步 FIFO；给 TB 改端口时两处都要同步。
3. `-Sizes` 要走数组：`-Sizes @("64x16","320x40")`。
   直接 `powershell -File ... -Sizes "a","b"` 在 VS Code 终端里会被拼成一个字符串。
