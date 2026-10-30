//=============================================================================
//  cfg_ctrl_top.v
//  配置控制顶层: I2C 从机 + 参数字符堆 + 跨时钟域
//
//  时钟域划分
//  --------
//    i_sys_clk (25MHz, 常开)  : I2C 从机 + 参数字符堆。
//      用常开时钟而不是像素时钟, 因为链路没起来时也要能配置。
//    i_pix_clk (S_hs_rx_clk)  : 预处理流水线。配置信号在这里被 2 级同步后使用。
//
//  为什么配置要跨时钟域
//  ------------------
//  配置是"准静态"的 —— 只在 I2C 写入时才变。但直接跨域仍可能采到亚稳态,
//  所以每个信号做 2 级触发器同步。多 bit 同时变化(如 mode 0->3)可能被采样到
//  不一致的瞬间, 但只影响一帧且预处理本身无状态, 可以接受。
//
//  帧计数: 在像素域对 tuser 计数, 同步回系统域供 I2C 回读 ——
//  可以据此确认链路在正常出帧。
//=============================================================================
`timescale 1ns / 1ps

module cfg_ctrl_top #(
	parameter [6:0]  DEV_ADDR = 7'h40,
	//=========================================================================
	// CFG_VER: 本 bit 流的构建版本号, 可通过 I2C 寄存器 0xA9(低)/0xAA(高) 读出。
	//   ★ **这里是唯一真源** —— system_top 已不再用 #(.CFG_VER()) 覆盖它。
	//   ★ 每次要烧到板上的构建都把这个号 +1, 否则无法确认板子上跑的是哪一版。
	//   (2026-10-17 就吃过一次亏: 改完 VMAX 以为烧了, 实测数据全是旧 bit 的,
	//    白分析了一轮"VMAX 不生效")
	//   (2026-10-25 又吃一次: 改的是这里的默认值, 但 system_top 里还硬写着
	//    .CFG_VER(16'h4704), 三处修复都编进 bit 了, 板上仍读 0x4704)
	//   编码: 高字节 = 大版本(hex), 低字节 = 该版本内的构建序号
	//     0x3504 = V35 第 4 次构建 (V35d: 4K VMAX=2788 想拿 25fps)
	//     0x4301 = V43 第 1 次构建 (修 4K 每行多 1~2 个 word 导致的斜向撕裂)
	//     0x450D = 单路最佳版 (已上板验证 1080p/4K 画面与颜色正常)
	//     0x4600 = V46 第 0 次构建: 双路 CSI (0xDB 选源), 上电默认 cam0
	//     0x4601 = V46 第 1 次构建: 调试寄存器 0xD6/D7/D8=cam0 固定,
	//              cam1 走 0xDD/DE/DF, 新增 0xDC 两路打包状态
	//     0x4700 = V47 第 0 次构建: 双目交替推流 (0xDB[1]) + 帧标记 (0xDB[2])
	//     0x4704 = V47 第 4 次构建 (工作区基线)
	//     0x4705 = V47 第 5 次构建 (已烧在板上, 早前产物)
	//     0x4706 = V47 第 6 次构建: 移除锐化; HE 内置斜率限制+跳帧 IIR, 删 0xFA
	//     0x4707 = V47 第 7 次构建: 窗口相位修正(flags/o_rgb 改 d3, 与窗口中心同拍)
	//               -> 高斯 5x5/7x7 与高级层不再横向错位;
	//               单色时强制 Cb=Cr=128 + 灰度也纳入白平衡旁路;
	//               HE 对比限制默认 8
	//     0x4708 = V47 第 8 次构建: **修直方图均衡的频闪(根本原因)**
	//               删掉帧间 IIR 平滑。仿真实证(tb_he_big.v, 1920 尺度/静止场景):
	//                 new=(ideal+3*prev)/4 是 τ=4 帧的一阶低通, 上电/切换后要
	//                 10~20 帧才收敛, 这段时间整帧亮度持续单调变化 = “闪”。
	//                 纯 HE 的帧间抖动只有 0.36%, 不需要 IIR;
	//                 噪点由 LUT 斜率限制(≤3)压住。
	//                 实测: 10 帧均值极差 3536 -> 172 (改善 ~20 倍), 第1帧即锁定。
	//     0x470A = V47 第 10 次构建: **JPEG 送 RK 的直通化 (0x0B[1]/[2])**
	//               - 0x0B[0] JPG_TX : 1 = MIPI 发 FPGA 硬件 JPEG 码流
	//               - 0x0B[1] DT18   : 长包 DT。0=0x1E (与 NV16 通道同 DT,
	//                   rkcif 当前配置只认这个, JPEG 字节占帧缓冲前段 ——
	//                   RK 端搜 FF D8..FF D9 直接推流, 零解码零重编码);
	//                   1=0x18 (标准 JPEG, 板上实测被 rkcif 拒收:
	//                   MIPI_CSI2 ERR2 0x10001100 "err id")
	//               - 0x0B[2] JPAD   : 帧尾补 0 到整帧 4147200B。1=补满
	//                   (rkcif 行为与 NV16 通路完全一致, 最稳妥, 占带宽);
	//                   0=短帧 (省带宽, 待板上验证收端能否接受)
	//               - 编码器帧字节数超整帧时自动截断, 保护链路
	//     0x470B = V47 第 11 次构建: **JPEG 编码器真正接入**
	//               0x470A 板上实测 0xA0~0xA2 恒 0 / 0xA8 bit0(busy) 恒 1
	//               => 编码器从来没出过一帧。根因是源 64bit(4px/拍) 只接了
	//               s_data[31:0](2px), 每拍丢一半 -> 行缓冲永远凑不满 8 行;
	//               且编码器挂在 S_hs_rx_clk(≈31MHz), 光时钟就只够 13fps。
	//               现在: jpeg_enc_if(异步FIFO拆字) -> 编码器(S_pclkx1 147.5MHz)
	//                     -> jpeg_byte_bridge -> csi2_frame_tx_var
	//               + 整帧门控(上一帧没编完就整帧丢) + 卡死看门狗(>54ms 复位)
	//               新增诊断: 0xA3/0xA4=源FIFO溢出次数, 0xA5/0xA6=看门狗次数,
	//                         0xA7=跨时钟桥背压低位
	//     0x470C = V47 第 12 次构建: 编码器时钟回退到 S_hs_rx_clk(31.25MHz)
	//               0x470B 把编码器挂到 S_pclkx1(147.5MHz), 时序报告实测
	//               fmax 只有 45.06MHz (最差路径 X_jpeg_qt 异步读 -> u_quant
	//               量化乘加 = 21.9ns, WNS -15.413ns / 2591 违例端点)
	//               => 147.5MHz 下编码结果必然是错的。先退回 31.25MHz 保功能:
	//                 150 clk/MCU x 16200 MCU / 31.25MHz = 77.8ms/帧 ≈ 13fps。
	//     0x470D = V47 第 13 次构建: **按赛题硬指标裁剪预处理, 腾 DSP**
	//               保留: 高斯 / 直方图均衡 / 灰度 / 对比度拉伸 / 阈值分割 /
	//                     形态学 / Sobel
	//               删除: 反色(0xF0 bit4)、中值、拉普拉斯、浮雕、Prewitt(0xB1 的 4~7 档)、
	//                     数字白平衡(0xC5/0xC6 的 R/B 增益乘法器)
	//               寄存器地址全部保持不变, 删掉的位写 1 不再有任何效果;
	//               0xB1 写 4~7 等价于 0(原图直通), 老脚本不会黑屏。
	//    ★ 网页「版本」格悬停会按 QUICKSTART 的登记表显示含义, 加版本时同步登记。
	//=========================================================================
	//     0x470E = V47 第 14 次构建: **编码器时钟回退到 70MHz + 三处资源优化, 供板上实测 JPEG 直通**
	//               起因: 147.5MHz 下布线 WNS -8 ~ -12ns, 编码结果不可信。
	//               回退: S_enc_clk = S_hs_rx_clk(70MHz), 16200x150/70M = 34.7ms -> 28.8fps。
	//               同时落地三处资源优化(降拥塞):
	//                 - demosaic 只留 RGGB 分支      (-12 ERAM, -711 LUT)
	//                 - AWB 除法器改 48 位串行      (-~5400 FF, -2168 进位链)
	//                 - 删除 7x7 高斯(第 3 遍 3x3)   (-10 ERAM); 0xF8 写 2 自动退到 5x5
	//               用 0x0B 控制: [0]=1 发 JPEG 码流, [1]=0 用 DT 0x1E, [2]=1 帧尾补零
	//     0x4710 = V47 第 16 次构建: **编码器状态诊断版 (临时调试, 仍 70MHz)**
	//               起因: 板上 0x470E 永远 st_busy=1、帧字节恒 0、看门狗 8.2 次/秒,
	//                     NV16 模式也拿不到数据（S_enc_busy_f 卡住把 S_enc_gate_r 关死）。
	//               新增只读抽头（不影响任何逻辑）:
	//                 0xEA/EB = 左引擎 o_diag 低/高
	//                 0xEC/ED = 右引擎 o_diag 低/高
	//                 0xEE    = 帧门控链状态
	//               位定义见 jpeg_encoder_top.v 的 o_diag 注释。
	//               本版只用于定位, 不用于验收。
	//     0x4711 = V47 第 17 次构建: **修上板死锁 + 加排水状态抽头 (仍 70MHz)**
	//               根因: csi2_frame_tx_var 在 !enable (即 0x0B[0]=0 的 NV16 模式) 分支
	//                     把 d_rd 清 0, 而写侧仍在攒包 -> pend_v 永久 1 -> s_tready 永久 0
	//                     -> 字节桥不排水 -> 段合并器卡死 -> 两个编码器卡死
	//                     -> S_enc_busy_f 卡住 -> 共享的 S_enc_gate_r 关死 -> NV16 也没图。
	//               修法: !enable 时改 d_rd <= d_wr (丢数据但保持 pend_v=0)。
	//               新增 0xEF: [1:0]S_jl_st [3]pad [4]S_jb_r [5]S_jv_rx_ready [6]S_jb_v [7]S_jb_l
	//     0x4712 = V47 第 18 次构建: **修 JLS_DROP 构造性死锁 (仍 70MHz)**
	//               现象: 0x4711 上板实测 S_jv_rx_ready=1 (上一处修复生效), 但 S_jl_st 恒=DROP。
	//               根因: 整条 case 包在 `else if (S_jv_v && S_jv_rx_ready)` 里, 而 DROP 让
	//                     S_jv_v=0 -> DROP 的退出条件永远不可能被求值。
	//               修法: DROP 移到发送门之外 + DROP 也抽排水桥 + 4096 拍超时兜底。
	//               0xEF bit2 改成 (S_jl_cnt > 4194304) 诊断位。
	//     0x5000 = V50 第 0 次构建 (2026-10-28): **JPEG 源改到 dbuf 读侧 + 四引擎**
	//               为什么必须改: 编码器速度(17.45ms/帧) 比输入(16.67ms) 慢 4.6%,
	//               接在 dbuf 写侧(实时流, 零缓冲)时帧编到 94% 就被下一个 SOF 关断
	//               -> 行缓冲断粮 -> 永久死锁 (板上 0xA0 恒 0 的真正原因)。
	//               改法: 源改接 dbuf 读侧 (DDR 三帧缓存) ->
	//                     yuv32_to_quad (32b/2px@147.5MHz -> 64b/4px@70MHz)
	//                     -> 行内 1/4 分组 -> 4x jpeg_enc_if -> 4x 编码器
	//                     -> jpeg_seg_merge4 -> 原有字节桥
	//               同时修 6 个仿真暴露的 bug (详见 docs/WORKLOG_2026-10-28_V50_*.md)
	//               仿真验收: 与基准 merged4.jpg **逐字节一致 (6007B)**
	//               资源: ERAM 215/272, DSP 182/240, SLICE 70.1%; S_clk_70m SWNS +0.584ns
	//               ★ 关键约束: 编码器行缓冲预取 8 行不得断粮, 所以 enc_if FIFO 加大到
	//                 2048 深且攒够 1920 word (8行) 才开始送 (START_LEVEL 参数)。
	//     0x5001 = V50b 临时构建 (2026-10-28): **固定图案链路自测**
	//               TX 源切到内置 TPG (1920x1080 模盘+网格+行号斜坡), 绕开
	//               IMX415/ISP/preproc/dbuf/packer, 只留 csi2_frame_tx + D-PHY TX。
	//               用途: 判定板上 MIPI_CSI2 的 CRC 满屏到底是 TX 链路问题还是上游。
	//               ★ 本版不用于验收, 测完必须把
	//                 system_top.v 的 JPEG_TEST_SRC 置 0 / TX_SRC_SEL 置 2'd0 恢复。
	//     0x5002 = V50c 临时构建 (2026-10-28): **LFSR 随机图案压链路**
	//               0x5001 用棋盘图案时: fps=50.4, frame_id 递增, MIPI_CSI2 错误=0,
	//               Page fault=0 —— TX/D-PHY/链路在规整图案下完全干净。
	//               本版把 TPG 改成 32 位 LFSR 伪随机 (最坏跳变), 用来区分:
	//                 出现 CRC  -> 数据相关的信号完整性余量不足 (降速率/加预加重/查硬件)
	//                 仍然干净  -> 链路对任意数据都 OK, 问题在 csi2_pack
	//     0x5003 = V50d (2026-10-28): **修 csi2_pack 丢失的整行预取门控**
	//               0x5001(TPG) 证明 TX/D-PHY/链路完全干净 (fps=50.4, CRC=0);
	//               走 packer 就 CRC 满屏 => 问题在 packer 的 m_tvalid 会掉拍。
	//               根因: V43 把 m_tvalid=line_active(带整行预取) 换成 4 深队列时
	//                     删掉了预取, 变成 m_tvalid=(q_cnt!=0);
	//                     而 TX 发一行 7.68us, VTC 源一行 18.5us, TX 快 2.4 倍,
	//                     一发包就饿死 -> s_tvalid 掉拍 -> packet 被截断 -> CRC。
	//               修法: 一行攒满(WORDS_PAYLOAD)才起发, 一旦开始放到行尾。
	//               恢复正式通路: JPEG_TEST_SRC=0, TX_SRC_SEL=0。
	//     0x5100 = V51 (2026-10-28): **移除 NV16, MIPI 只发 JPEG**
	//               背景: NV16 3840x1080@60 需要 498MB/s, 而 4lane 1000Mbps
	//                     只有 500MB/s (99.6% 利用率), 且每行 2123 byte_clk
	//                     @125MHz = 16.96us 超过 VTC 的 14.91us 行预算 13.7%
	//                     => 结构上不可能, TPG 实测上限就是 50.4fps。
	//               删除: csi2_pack_yuv422_stream / csi2_frame_tx(定长) /
	//                     csi2_test_src / 读侧帧标记注入 / TX_SRC_SEL mux。
	//               保留: ui_dbuf.R -> yuv32_to_quad -> 4x编码器 -> 段合并 ->
	//                     jpeg_byte_bridge -> csi2_frame_tx_var -> D-PHY TX。
	//               寄存器: 0x0B[0] 锁死 1 (JPEG), 0x0B[1] 锁死 0 (DT 仍为
	//                       0x1E, rkcif 没有 JPEG 支持), 0x0B[2] JPAD 默认 0。
	//     0x5101 = V51b (2026-10-28): **修段合并选择器的单向锁存**
	//               板上 0x5100 实测: 引擎0 diag=0x1442 (T_HDR, m_ready=0)、
	//               引擎3 diag=0x1167 (T_NEXT, huff_run=1, bp_ok=0),
	//               6 次采样 3 秒内完全一致 = 硬冻结; 看门狗 9/s 响但救不活。
	//               根因: jpeg_seg_merge4.sel 只在引擎0 busy 上升沿归零,
	//                     看门狗软复位后 busy 没有下降沿 -> sel 卡在 1/2 永不归零
	//                     -> 引擎0 没被选中 -> 帧头吐不出 -> 段完不成 -> 死锁。
	//               修法: 软复位释放那一拍也强制 i_start (sel 归零 + done_p 清空)。
	//               诊断: 0xA5/0xA6 改为 {encif_full[3:0], jcfg_consume, mrg_segc[9:0]}。
	//     0x5200 = V52 (2026-10-29): **修复与单目完美版 0x450D 交叉验证出的唯一回归**
	//               0x450D 的 CSI-2 组包器 `u_csi2_frame_tx.clk = S_dsi_byte_clk`,
	//               与 D-PHY 的 I_hs_clk **同一根时钟**, 零跨域。
	//               V51 把 JPEG 的 `csi2_frame_tx_var` 放到了 S_hs_rx_clk = 70.24MHz,
	//               而 D-PHY 仍是 S_dsi_byte_clk = 125MHz => hs_en/hs_data[31:0]/hs_last
	//               32 位裸跨时钟, 125/70.24 = 1.78 非整数比 => 每个 70MHz 数据拍被
	//               采 1 或 2 次 => 随机重复/丢字节, 码流不可能正确。
	//               改法: 字节桥读侧 + S_jl_* 补零/丢弃状态机 + var 组包 全部搬到
	//                     S_dsi_byte_clk; jpeg_byte_bridge 本来就是异步 FIFO,
	//                     它成为唯一的 CDC 点, 组包器与 D-PHY 之间重新零跨域。
	//     0x5201 = V52b (2026-10-29): **字节桥排水诊断** (纯观测, 不改数据通路)
	//               0x5200 板上实测把死锁钉到 byte_bridge:
	//                 0xA5/A6=0x00/0x10 => encif_full=0x1, consume=0, mrg_segc=0
	//                 引擎0=0x1442 => T_HDR, lb_avail=1, m_ready=0
	//                 mrg_segc=0 => sel 未前进 => m_ready=0 只能来自 o_ready_down=0
	//                 => 桥满 (w_ready=~f_full)
	//               本版用已作废的 0xE4/0xE5 暴露:
	//                 0xE4 = 桥读侧已读出字节计数 (8bit, 每次握手+1)
	//                 0xE5 = 桥读侧剩余字节数低 8 位 (511 满 -> 读回 0xFF 附近)
	//               判定: rcnt 在变 => 桥在排水, 只是速率限住;
	//                     rcnt 不变 + lvl 贴满 => 读侧死了。
	//               同时 0xEF[2] 由"jl_cnt>4M"改为 dsi_pll_lock ——
	//               S_tx_domain_rst_n 含它, 它若为 0 桥读侧会被按在复位里,
	//               表现与"读侧死了"一模一样, 必须先排除。
	//
	//     0x5301 = V53a (2026-10-29): **死锁根治, 时钟仍 70.238MHz (≈57fps)**
	//               死锁根因 (完整链路仿真 tb_jpeg_full 与板上 0x5200 完全一致):
	//                 jpeg_seg_merge4 是 4:1 **串行** mux, 一个引擎的 seg 不结束,
	//                 另外三路 o_ready 恒 0; 而 jpeg_bitpack 只有约 8 字节输出弹性。
	//                 => 桥一满 -> mux 阻塞 -> 三路引擎 8 字节憋死 -> 卡 T_NEXT
	//                 -> enc_if 填满 -> 全局死锁。
	//               仿真三组对照:
	//                 桥 512B  + 预取 8 行  : TIMEOUT (复现板上现象)
	//                 桥 4KB   + 预取 8 行  : 仍 TIMEOUT (桥 level=4094 贴满)
	//                 桥 4KB   + 预取 16 行 : PASS, 6007 B 与黄金基准逐字节相同
	//                                       H=32 与 H=64 均 PASS (排除尺度假象)
	//               本版改动 (只这两项, PLL 未动):
	//                 ① jpeg_byte_bridge   AW  9 -> 12 (512B -> 4KB)
	//                 ② jpeg_enc_if        AW 11 -> 12, START_LEVEL 1920 -> 3840 (16 行)
	//               为什么不再改时钟 (用户要求"先按 57 做"):
	//                 编码器 8100 MCU x 151.3 clk / 70.238MHz = 17.45ms -> 57.3fps,
	//                 低于 VTC 的 59.6fps。若改 C3 为 20 分频 (73.75MHz) 可得
	//                 16.62ms -> 60.2fps, 但 clk0 实测 Fmax 仅 73.872MHz,
	//                 余量只剩 0.16%, 故先出 57fps 画面, 60fps 留作下一步 A/B。
	//
	//     0x5302 = V53b (2026-10-29): **合并器 i_start 根因修复 (这才是真正的死锁)**
	//               0x5301 板上实测: 桥零字节 (lvl=0/rcnt=0/st_bp=0), mrg_segc=0,
	//                 一路 encif_full=1, consume=0, stall=746 且每 3s +25,
	//                 eng0=0x1442(T_HDR,m_ready=0), eng3=0x1167(T_NEXT,pend=2,bp_ok=0)
	//                 —— 与 V52 **逐位相同**, 说明桥深度/预取深度都不是瓶颈。
	//               台架 tb_wd 只改 m_start 一行, 其余全同 (70.238MHz + AW(12) + 16 行):
	//                 m_start = 引擎0 busy 上升沿 (原接法) -> MERGED=6620(错), segcnt=0,
	//                                                          **引擎1/2 输出 0 字节**
	//                 m_start = 只由 S_enc_rst_rel 触发      -> MERGED=6007 逐字节正确,
	//                                                          segcnt=19, 1303/1394/1303/1392
	//               根因: i_start 会清 sel/done_p, 而引擎0 的 st_busy 不是帧起始指示器
	//                 (i_soft_rst 清 0、帧尾也清 0, i_en 恒 1 又立刻置 1), 上传沿会在
	//                 帧中间反复出现 -> sel 被拽回 0 -> 引擎1/2 永远轮不到 ->
	//                 bitpack 8 字节弹性憋死 -> enc_if 填满 -> 全局 AND 反压饿死四路 ->
	//                 源断流 -> 看门狗 114ms 复位 -> i_flush 又清 rd_go 且攒不满 16 行
	//                 -> **永久死锁, 看门狗永远救不活**。
	//               修法: S_mrg_start = S_enc_rst_rel (段序本身就是 0..3 循环)。
	//
	//     0x5303 = V53c (2026-10-29): **纯只读抽头, 不动任何逻辑**
	//               0x5302 板上实测仍为 零帧/桥零字节/mrg_segc=0/stall 每 114ms+1,
	//               eng0=0x1442、eng3=0x1167 依旧逐位不变 => 还有更靠前的阻塞点。
	//               现有寄存器区分不了「sel≠0」和「桥 f_full 假报满」, 也看不到
	//               dual_stitch 的状态, 所以一次把下面这些都挂出来:
	//
	//               ---- 拼接器 (dual_stitch / sensor_sync_start) ----
	//               0xE1 = st_frames[ 7:0]   已输出帧数（成帧数，最关键的判据）
	//               0xE3 = st_frames[15:8]
	//               0xDC = st_l_ovf[ 7:0]    左路补零/丢弃次数（数据完整性告警）
	//               0xD4 = st_lines[ 7:0]    已输出行数
	//               0xD5 = st_r_ovf[ 7:0]    右路补零/丢弃次数
	//               0xE2 = st_l_starve[7:0]  左路掉线恢复次数
	//               0xE8 = st_r_starve[7:0]  右路掉线恢复次数
	//                 => 两路都有帧的判据: st_frames 在涨, 且 l/r_starve 不再增长、
	//                    l/r_ovf 不涨。掉一路: 对应 starve 会一直涨。
	//               ⚠ st_* 在 70MHz 域被 25MHz 采样, 多 bit 会有脏快照,
	//                 但这几个是慢变计数器, 看"是否为 0 / 在不在涨"是可靠的。
	//
	//               ---- JPEG 引擎/桥 ----
	//               0xE6 = {S_yuv_de, S_jcfg_valid, S_jcfg_consume, 4'b0, S_jpeg_m_ready}
	//                      bit0=0 直接证明桥的 f_full 一直为 1（不是 sel 的问题）
	//               0xE7 = 引擎1 o_diag[7:0]   (bit3:0 = tstate)
	//               0xE9 = 引擎2 o_diag[7:0]
	//                 => 配合 0xEA/EB(eng0)、0xEC/ED(eng3) 四路状态全可见
	//
	//     V54 (0x5400) 2026-10-30:
	//       PLL C3 70.238 -> 73.75MHz, JPEG 一帧 17.45ms -> 16.62ms (57.3 -> 60.19fps)
	//       其余寄存器定义与 0x5303 完全相同。详见 docs/V54_60FPS.md
	//
	//     V54c (0x5401) 2026-10-30: 只改 RTL 逻辑, 寄存器定义不变
	//       ① system_top: jpeg_seg_merge4 的 o_ready 驱动方向修好
	//          (原来 S_jm_rdy_p 被 {S_jm_rdy} 组合驱动又多驱动, o_ready 被解析成 0
	//           => 四引擎 m_ready 全 0 => 完全无画面)
	//       ② system_top: 源侧反压改成只看当前段那一路 (~(|S_encif_full) 会一路满饿死四路)
	//       ③ jpeg_seg_merge4: sel 无进展超时兜底 (SEL_TO=262143 拍)
	//       台架: 3840x256 从 FAIL(ENG by 0/0/0/0) 变成
	//             PASS(ENG by 80927x3/80925, MERGED 324321, segcnt 963, ovf 0)
	//     V54e (0x5402) 2026-10-30: 回退源侧反压策略, 寄存器定义不变
	//       V54c 把 S_jcfg_consume 从"四路取与"改成"只看当前段那一路",
	//       板上实测 0xA3~A6 出现 ovf=1 / mrg_segc=0, 画面大片绿(色度全丢)。
	//       根因: dbuf 读侧 147.5MHz 一行 13.0us x 1080 = 14.06ms 灌完,
	//             而 4 引擎编码一帧要 16.62ms => 输入快 2.6ms, FIFO 必满。
	//       回退成四路取与(任一路满就停读 dbuf, 数据留在 DDR),
	//       保留 V54c 的 mux o_ready 修复 + sel 超时兜底。
	parameter [15:0] CFG_VER = 16'h5408
)(
	// ---- 系统时钟域 (25MHz 常开) ----
	input  wire        i_sys_clk,
	input  wire        i_sys_rst_n,

	// ---- I2C 引脚 (三态在顶层处理) ----
	input  wire        i_scl,
	input  wire        i_sda,
	output wire        o_sda_drive,

	// ---- 像素时钟域 ----
	input  wire        i_pix_clk,
	input  wire        i_pix_rst_n,
	input  wire        i_frame_tuser,      // (旧) ISP 输出帧首 — 实测恒为 0, 仅保留端口
	// V36 诊断: 真正能用的帧首信号 (都在 i_pix_clk 域)
	input  wire        i_fs_csi,           // CSI-2 FS 短包 -> 传感器真实帧率
	input  wire        i_fs_corr,          // ui_image_correction 输出帧首
	input  wire        i_last_corr,        // ui_image_correction 行尾
	// V21 诊断: 一行的像素组数 (来自 i_pix_clk 域)
	input  wire [15:0] i_line_groups,

	// 2026-10-20: LP-free RX 调试总线 (i_pix_clk 域, 内部 2 级同步到 i_sys_clk)
	input  wire [7:0]  i_dbg_mipi,
	input  wire [7:0]  i_dbg_delay,
	input  wire [5:0]  i_dbg_best_len,
	input  wire        i_dbg_autodone,
	// 2026-10-21 双路: cam1 的完全独立一套 (0xDD/0xDE/0xDF)
	//   ⚠ 不能让这两路走同一根「按源选」的总线 —— S_rx_sel_rx 的同步器挂在
	//     S_hs_rx_clk 上, 切到没摄像头的源时时钟停摆、选源位会卡住,
	//     导致调试寄存器显示的是上一个源的数据 (实测踩过, 差点误判)。
	//     这里两路各自同步、各自独立回读, 没有任何选源环节。
	input  wire [7:0]  i_dbg1_mipi,
	input  wire [7:0]  i_dbg1_delay,
	input  wire [5:0]  i_dbg1_best_len,
	input  wire        i_dbg1_autodone,

	// ---- 同步到像素域的配置输出 ----
	output wire [3:0]  o_pp_mode,          // 高级单选 0..8
	output wire [4:0]  o_pp_sobel_gain,
	output wire [7:0]  o_pp_thresh,
	output wire        o_pp_morph_sel,
	output wire [7:0]  o_pp_morph_th,

	// V54k: 量化表写入透传 (0x10~0x8F) -> system_top -> jpeg_qtable_ram
	output wire        o_qt_wr_en,
	output wire [7:0]  o_qt_wr_addr,
	output wire [7:0]  o_qt_wr_data,
	output wire [4:0]  o_pp_lap_gain,
	output wire [4:0]  o_pp_prew_gain,
	output wire [3:0]  o_pp_emboss_gain,
	output wire [7:0]  o_pp_emboss_bias,
	// 初级预处理 (V45, 多选位图)
	output wire [4:0]  o_basic_en,
	output wire        o_basic_gray,
	output wire [3:0]  o_basic_gauss,
	output wire [1:0]  o_basic_ker,
	output wire [7:0]  o_basic_he,
	output wire [7:0]  o_basic_he_clip,
	output wire        o_basic_linefix,
	output wire [3:0]  o_basic_contrast,

	// ---- 摄像头参数 (直接给 system_top 里的 cam_param, 同在 25MHz 域) ----
	output wire [19:0] o_cam_exp,
	output wire [7:0]  o_cam_gain,
	output wire [3:0]  o_cam_ev,
	output wire [7:0]  o_cam_trig,
	input  wire [15:0] i_cam_wr_cnt,
	input  wire        i_cam_busy,
	// 2026-10-27: JPEG 支路诊断 —— 0xA3~0xA6 = {看门狗触发次数, 源FIFO溢出次数},
	//   0xA7 = byte_bridge 写侧背压低 8 位。编码器从没出过帧时靠这几个数定位。
	input  wire [31:0] i_dbg_jpeg,
	input  wire [7:0]  i_dbg_jb,
	// 2026-10-21 画面冻结定位 (已 2 级同步到 i_sys_clk)
	input  wire [7:0]  i_diag_sof,
	// 2026-10-21: FPGA 硬件 JPEG 编码器的状态回读
	input  wire [23:0] i_jpeg_bytes,
	input  wire        i_jpeg_busy,
	input  wire        i_jpeg_done,
	// 2026-10-21: MIPI 输出源选择 (0x0B) —— 0=原 NV16 直通, 1=JPEG 码流
	output wire        o_jpeg_tx,
	// 2026-10-27: 0x0B[1]=DT18 (JPEG 长包 DT), 0x0B[2]=JPAD (帧尾补零到整帧)
	output wire        o_jpeg_dt18,
	output wire        o_jpeg_pad,
	input  wire [7:0]  i_diag_wbuf,
	input  wire [7:0]  i_diag_vs,
	input  wire [15:0] i_diag_lg1,
	input  wire [7:0]  i_diag_tlast,
	input  wire [7:0]  i_diag_rxck,
	input  wire [7:0]  i_diag_c1ck,
	input  wire [7:0]  i_diag_rtv,
	// ★ V53c: 拼接器(sensor_sync_start)的数据完整性告警 —— 原来这两个信号
	//   **根本没接到寄存器**, 白浪费。 
	//     0xDC      = i_dbg_status      = 左路补零/丢弃次数低 8 位
	//     0xD4/0xD5 = i_st_line_groups  = {右路补零/丢弃次数低8位, 已输出行数低8位}
	//   ⚠ 两者都在 S_hs_rx_clk (73.75MHz), 下面用 2 级同步到 i_sys_clk(25MHz)。
	//     慢变计数器, 看趋势/是否为 0 可靠; 多 bit 快照可能脏一拍, 不在意。
	input  wire [7:0]  i_dbg_status,
	input  wire [15:0] i_st_line_groups,
	// V54f 诊断: rgb_to_yuv422_quad 抽头 (在 S_hs_rx_clk 域, 下面 2 级同步)
	//   0x0C~0x0F = {tog, in_b, in_g, in_r}          rgb2yuv 输入 pix0
	//   0xFC~0xFF = {out_cr, out_y1, out_cb, out_y0} rgb2yuv 输出 pair0
	input  wire [31:0] i_dbg_rgbin,
	input  wire [31:0] i_dbg_yuvout,
	// V54i 诊断: cam0(右路) 掉线恢复次数 (0xCA/0xCB)
	input  wire [15:0] i_dbg_cam0_starve,
	// 2026-10-28 诊断 (临时调试版): JPEG 编码器内部状态 (0xEA~0xEE)
	input  wire [15:0] i_diag_enc_l,
	input  wire [15:0] i_diag_enc_r,
	input  wire [7:0]  i_diag_enc_t,
	input  wire [7:0]  i_diag_jv,

	// ---- 画质参数 (同步到像素域) ----
	output wire [7:0]  o_wb_r,
	output wire [7:0]  o_wb_b,
	output wire [6:0]  o_roi_pct,
	output wire [2:0]  o_fps_div,
	// V21: 分辨率模式 (0=1080p60 默认, 1=4K30) + 变更脉冲
	output wire [1:0]  o_res_mode,
	output wire        o_res_chg,
	// 2026-10-21: CSI RX 手动 tap 步进按钮 (idle=1, 写 0xD9 产生一次按下->释放)
	output wire        o_dbg_btn,
	// 2026-10-21: Bayer 相位 (0=RGGB 1=GRBG 2=GBRG 3=BGGR), 已同步到像素域
	output wire [1:0]  o_bayer_sel,
	// 2026-10-21: CSI 源选择 (0xDB), 0=cam0(J2) 1=cam1(J3)。
	//   这里只做**原样透出**, 同步与复位窗由 system_top 做 ——
	//   因为它要同时驱动时钟 mux (必须在时钟域外) 和写侧复位窗。
	output wire        o_rx_sel,
	// 2026-10-21 双目交替
	output wire        o_dual_en,      // 0xDB[1]: 1 = 双目交替, 各 30fps
	output wire        o_mark_en,      // 0xDB[2] | dual: 帧标记使能
	output wire        o_dual_start    // 写 0xDB 且进双目时的一拍脉冲
);

	//-------------------------------------------------------------------------
	// 上电复位 (系统时钟域)
	//-------------------------------------------------------------------------
	reg [3:0] rst_cnt = 4'd0;
	always @(posedge i_sys_clk)
		if (rst_cnt != 4'hF) rst_cnt <= rst_cnt + 4'd1;
	wire sys_rst_n = i_sys_rst_n & (rst_cnt == 4'hF);

	//-------------------------------------------------------------------------
	// 参数字符堆
	//-------------------------------------------------------------------------
	wire        wr_en;
	wire [7:0]  wr_addr, wr_data;
	wire [7:0]  rd_addr, rd_data;

	wire        cfg_pp_en;
	wire [3:0]  cfg_pp_mode;
	wire [4:0]  cfg_pp_sh;
	wire [7:0]  cfg_pp_th;
	wire        cfg_pp_ms;
	wire [7:0]  cfg_pp_morph_th;
	wire [4:0]  cfg_pp_lap_sh;
	wire [4:0]  cfg_pp_prew_sh;
	wire [3:0]  cfg_pp_emboss_gain;
	wire [7:0]  cfg_pp_emboss_bias;

	wire [4:0]  cfg_basic_en;
	wire        cfg_basic_gray;
	wire [3:0]  cfg_basic_gauss;
	wire [1:0]  cfg_basic_ker;
	wire [7:0]  cfg_basic_he;
	wire [7:0]  cfg_basic_he_clip;
	wire        cfg_basic_linefix;
	wire [3:0]  cfg_basic_contrast;
	wire        cfg_soft_rst;
	wire        cfg_lossless, cfg_bypass, cfg_single, cfg_rc_en;
	wire [6:0]  cfg_quality;
	wire [23:0] cfg_target;
	wire [3:0]  cfg_rc_speed;
	wire [1:0]  cfg_subsample;
	wire [7:0]  cfg_restart;
	wire [2:0]  cfg_predictor;

	// 摄像头 / 画质参数
	wire [19:0] cfg_cam_exp;
	wire [7:0]  cfg_cam_gain;
	wire [3:0]  cfg_cam_ev;
	wire [7:0]  cfg_cam_trig;
	wire [7:0]  cfg_wb_r, cfg_wb_b;
	wire [1:0]  cfg_bayer_sel;
	wire        cfg_rx_sel;     // 2026-10-21: 0xDB CSI 源选择 (0=cam0 1=cam1)
	wire        cfg_dual_en;    // 2026-10-21: 0xDB[1]
	wire        cfg_mark_en;    // 2026-10-21: 帧标记
	wire        cfg_dual_start; // 2026-10-21: 双目同步启动脉冲
	// 2026-10-21: bsel 是 o_bayer_sel 的本源, 而 o_bayer_sel 的 assign 写在
	//   第 274 行 —— 声明必须放在那里之前, 否则 Verilog 会把 bsel_s2 隐式
	//   声明成 1bit, o_bayer_sel 只剩 bit0, GRBG(1)/GBRG(2)/BGGR(3) 全部混完。
	//   (和之前 S_pp_* / 模式切换复位窗踩的是同一个坑)
	reg  [1:0]  bsel_s1, bsel_s2;
	wire [6:0]  cfg_roi_pct;
	wire [2:0]  cfg_fps_div;
	reg  [15:0] lg_s1, lg_s2;   // V21 诊断同步器
	reg  [15:0] lg_max;         // V21 诊断: 历史最大行组数
	wire [1:0]  cfg_res_mode;   // V21
	wire        cfg_res_chg;    // V21
	wire        cfg_jpg_tx;     // 2026-10-21: 0x0B MIPI 输出源选择
	assign o_jpeg_tx = cfg_jpg_tx;
	// 2026-10-27: 0x0B[1]/[2]。★ 声明必须在使用点(X_jv 例化在 system_top)之前 ——
	//   这两根线在 system_top 里被 ifdef 内部引用, 由本模块驱动。
	wire        cfg_jpg_dt18;
	wire        cfg_jpg_pad;
	assign o_jpeg_dt18 = cfg_jpg_dt18;
	assign o_jpeg_pad  = cfg_jpg_pad;

	// 帧计数 (像素域), 同步回系统域供回读
	// ★★ V37: 这些声明必须放在 jpeg_regfile 例化**之前**。
	//    V36 把 `wire [15:0] st_corr_fc = corr_t2[15:0];` 写在了例化之后的 229 行,
	//    但 166 行已经用到了它 => Verilog 在用法处隐式生成了一个 **1bit** net,
	//    于是 0xD0/0xD1 只接到 bit0, 读出来永远是 0 (TD 警告 HDL-7225)。
	//    诊断仪表自己的 bug 差点又被当成"真的没数据"。
	reg  [31:0] cnt_csi_pix, cnt_corr_pix, cnt_line_pix;
	reg  [31:0] cnt_s1, cnt_s2;
	reg  [31:0] csi_t1, csi_t2, corr_t1, corr_t2, line_t1, line_t2;
	wire [15:0] st_corr_fc = corr_t2[15:0];

	// 2026-10-20: RX 调试总线 2 级同步 (i_pix_clk -> i_sys_clk)
	//   值都是慢变化的电平, 2 级同步足够; 读 0xD6~0xD8 即可。
	reg  [7:0] dbg_mipi_s1,  dbg_mipi_s2;
	reg  [7:0] dbg_delay_s1, dbg_delay_s2;
	reg  [5:0] dbg_blen_s1,  dbg_blen_s2;
	reg        dbg_adone_s1, dbg_adone_s2;
	// 2026-10-21 双路: cam1 一套独立同步器
	reg  [7:0] dbg1_mipi_s1,  dbg1_mipi_s2;
	reg  [7:0] dbg1_delay_s1, dbg1_delay_s2;
	reg  [5:0] dbg1_blen_s1,  dbg1_blen_s2;
	reg        dbg1_adone_s1, dbg1_adone_s2;
	// 0xDC: 两路实时状态打包 (bit 定义见 jpeg_regfile 注释)
	wire [7:0] cfg_dbg_status = {
		&dbg1_mipi_s2[3:0],   // bit7 cam1 四lane字节对齐全有效
		&dbg_mipi_s2[3:0],    // bit6 cam0 四lane字节对齐全有效
		dbg1_mipi_s2[7],      // bit5 cam1 unpack_valid (真的在吐像素)
		dbg_mipi_s2[7],       // bit4 cam0 unpack_valid
		dbg1_adone_s2,        // bit3 cam1 eye-scan 完成
		dbg_adone_s2,         // bit2 cam0 eye-scan 完成
		dbg1_mipi_s2[5],      // bit1 cam1 in_frame
		dbg_mipi_s2[5]        // bit0 cam0 in_frame
	};
	// 2026-10-21: 手动 tap 步进按钮 (idle=1)
	wire       cfg_dbg_btn;
	// ★ V53c: 拼接器行数/补零次数 2 级同步 (S_hs_rx_clk -> i_sys_clk)
	//   注意: 原来的 0xDC 是 cfg_dbg_status(RX 状态打包), 已改成左路补零次数,
	//   RX 的逐 lane 状态仍旧看 0xD6/D7/D8 (cam0) 和 0xDD/DE/DF (cam1)。
	reg  [7:0]  dbg_st_s1, dbg_st_s2;
	reg  [15:0] lg_st_s1,  lg_st_s2;
	// V54f 诊断: rgb2yuv 抽头 2 级同步 (S_hs_rx_clk -> i_sys_clk)
	reg  [31:0] D_in_s1,  D_in_s2;
	reg  [31:0] D_out_s1, D_out_s2;
	reg  [15:0] C0ST_s1,  C0ST_s2;
	always @(posedge i_sys_clk or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			dbg_st_s1 <= 8'd0;  dbg_st_s2 <= 8'd0;
			lg_st_s1  <= 16'd0; lg_st_s2  <= 16'd0;
			D_in_s1  <= 32'd0; D_in_s2  <= 32'd0;
			D_out_s1 <= 32'd0; D_out_s2 <= 32'd0;
			C0ST_s1  <= 16'd0; C0ST_s2  <= 16'd0;
		end else begin
			dbg_st_s1 <= i_dbg_status;      dbg_st_s2 <= dbg_st_s1;
			lg_st_s1  <= i_st_line_groups;  lg_st_s2  <= lg_st_s1;
			D_in_s1   <= i_dbg_rgbin;       D_in_s2   <= D_in_s1;
			D_out_s1  <= i_dbg_yuvout;      D_out_s2  <= D_out_s1;
			C0ST_s1   <= i_dbg_cam0_starve; C0ST_s2   <= C0ST_s1;
		end
	end
	always @(posedge i_sys_clk or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			dbg_mipi_s1  <= 8'd0; dbg_mipi_s2  <= 8'd0;
			dbg_delay_s1 <= 8'd0; dbg_delay_s2 <= 8'd0;
			dbg_blen_s1  <= 6'd0; dbg_blen_s2  <= 6'd0;
			dbg_adone_s1 <= 1'b0; dbg_adone_s2 <= 1'b0;
			dbg1_mipi_s1  <= 8'd0; dbg1_mipi_s2  <= 8'd0;
			dbg1_delay_s1 <= 8'd0; dbg1_delay_s2 <= 8'd0;
			dbg1_blen_s1  <= 6'd0; dbg1_blen_s2  <= 6'd0;
			dbg1_adone_s1 <= 1'b0; dbg1_adone_s2 <= 1'b0;
		end else begin
			dbg_mipi_s1  <= i_dbg_mipi;      dbg_mipi_s2  <= dbg_mipi_s1;
			dbg_delay_s1 <= i_dbg_delay;     dbg_delay_s2 <= dbg_delay_s1;
			dbg_blen_s1  <= i_dbg_best_len;  dbg_blen_s2  <= dbg_blen_s1;
			dbg_adone_s1 <= i_dbg_autodone;  dbg_adone_s2 <= dbg_adone_s1;
			dbg1_mipi_s1  <= i_dbg1_mipi;     dbg1_mipi_s2  <= dbg1_mipi_s1;
			dbg1_delay_s1 <= i_dbg1_delay;    dbg1_delay_s2 <= dbg1_delay_s1;
			dbg1_blen_s1  <= i_dbg1_best_len; dbg1_blen_s2  <= dbg1_blen_s1;
			dbg1_adone_s1 <= i_dbg1_autodone; dbg1_adone_s2 <= dbg1_adone_s1;
		end
	end

	jpeg_regfile #(.JPEG_VER(CFG_VER)) u_regfile (
		.I_clk           (i_sys_clk),
		.I_rst_n         (sys_rst_n),
		.I_wr_en         (wr_en),
		.I_wr_addr       (wr_addr),
		.I_wr_data       (wr_data),
		.I_rd_addr       (rd_addr),
		.O_rd_data       (rd_data),
		.O_cfg_lossless  (cfg_lossless),
		.O_cfg_bypass    (cfg_bypass),
		.O_cfg_single    (cfg_single),
		.O_cfg_quality   (cfg_quality),
		.O_cfg_target_bytes (cfg_target),
		.O_cfg_rc_en     (cfg_rc_en),
		.O_qt_wr_en      (o_qt_wr_en),
		.O_qt_wr_addr    (o_qt_wr_addr),
		.O_qt_wr_data    (o_qt_wr_data),
		.O_cfg_rc_speed  (cfg_rc_speed),
		.O_cfg_jpg_tx    (cfg_jpg_tx),
		.O_cfg_jpg_dt18  (cfg_jpg_dt18),
		.O_cfg_jpg_pad   (cfg_jpg_pad),
		.O_cfg_subsample (cfg_subsample),
		.O_cfg_restart_int(cfg_restart),
		.O_cfg_predictor (cfg_predictor),
		.O_soft_rst      (cfg_soft_rst),
		.I_st_frame_bytes(i_jpeg_bytes),
		.I_st_total_bytes(i_dbg_jpeg),
		.I_st_scale      (i_dbg_jb  ),
		.I_st_busy       (i_jpeg_busy),
		.I_st_frame_done (i_jpeg_done),
		.I_st_overflow   (1'b0),
		.I_qtable_rd_data(8'h00),
		.O_cfg_pp_en     (cfg_pp_en),
		.O_cfg_pp_mode   (cfg_pp_mode),
		.O_cfg_pp_sobel_shift (cfg_pp_sh),
		.O_cfg_pp_thresh (cfg_pp_th),
		.O_cfg_pp_morph_sel (cfg_pp_ms),
		.O_cfg_pp_morph_th  (cfg_pp_morph_th),
		.O_cfg_pp_lap_shift (cfg_pp_lap_sh),
		.O_cfg_pp_prew_shift(cfg_pp_prew_sh),
		.O_cfg_pp_emboss_gain(cfg_pp_emboss_gain),
		.O_cfg_pp_emboss_bias(cfg_pp_emboss_bias),

		.O_cfg_basic_en      (cfg_basic_en),
		.O_cfg_basic_gray    (cfg_basic_gray),
		.O_cfg_basic_gauss   (cfg_basic_gauss),
		.O_cfg_basic_ker     (cfg_basic_ker),
		.O_cfg_basic_he      (cfg_basic_he),
		.O_cfg_basic_he_clip (cfg_basic_he_clip),
		.O_cfg_basic_linefix(cfg_basic_linefix),
		.O_cfg_basic_contrast(cfg_basic_contrast),
		.I_st_frame_cnt  (cnt_s2),
		.O_cfg_cam_exp   (cfg_cam_exp),
		.O_cfg_cam_gain  (cfg_cam_gain),
		.O_cfg_ev_bias   (cfg_cam_ev),
		.O_cfg_wb_r      (cfg_wb_r),
		.O_cfg_wb_b      (cfg_wb_b),
		.O_cfg_fps_div   (cfg_fps_div),
		.O_cfg_roi_pct   (cfg_roi_pct),
		.O_cfg_cam_trig  (cfg_cam_trig),
		.O_cfg_res_mode  (cfg_res_mode),   // V21
		.O_res_chg       (cfg_res_chg),    // V21
		.O_cfg_bayer_sel (cfg_bayer_sel),  // 2026-10-21
		.O_cfg_rx_sel    (cfg_rx_sel),     // 2026-10-21: 0xDB
		.O_cfg_dual_en   (cfg_dual_en),    // 2026-10-21
		.O_cfg_mark_en   (cfg_mark_en),    // 2026-10-21
		.O_dual_start    (cfg_dual_start), // 2026-10-21
		.I_st_cam_wr_cnt (st_corr_fc),
		.I_st_cam_busy   (i_cam_busy),
		// 2026-10-21 画面冻结定位
		.I_diag_sof      (i_diag_sof),
		.I_diag_wbuf     (i_diag_wbuf),
		.I_diag_vs       (i_diag_vs),
		.I_diag_lg1      (i_diag_lg1),
		.I_diag_tlast    (i_diag_tlast),
		.I_diag_rxck     (i_diag_rxck),
		.I_diag_c1ck     (i_diag_c1ck),
		.I_diag_rtv      (i_diag_rtv),
		.I_diag_enc_l    (i_diag_enc_l),
		.I_diag_enc_r    (i_diag_enc_r),
		.I_diag_enc_t    (i_diag_enc_t),
		.I_diag_jv       (i_diag_jv),
          .I_st_line_groups(lg_st_s2),
          // V54f 诊断: rgb2yuv 抽头
          .I_dbg_rgbin    (D_in_s2),
          .I_dbg_yuvout   (D_out_s2),
          .I_dbg_cam0_starve(C0ST_s2),
          // 2026-10-20: RX 调试总线 (已 2 级同步到 i_sys_clk)
          // 2026-10-21: 0xD6/D7/D8 固定是 cam0, cam1 固定走 0xDD/DE/DF
          .I_dbg_mipi      (dbg_mipi_s2),
          .I_dbg_delay     (dbg_delay_s2),
          .I_dbg_best_len  (dbg_blen_s2),
          .I_dbg_autodone  (dbg_adone_s2),
          .I_dbg1_mipi     (dbg1_mipi_s2),
          .I_dbg1_delay    (dbg1_delay_s2),
          .I_dbg1_best_len (dbg1_blen_s2),
          .I_dbg1_autodone (dbg1_adone_s2),
          .I_dbg_status    (dbg_st_s2),          .O_dbg_btn       (cfg_dbg_btn)
  );

	assign o_dbg_btn = cfg_dbg_btn;
	assign o_bayer_sel = bsel_s2;   // 2026-10-21: 已在像素域
	assign o_rx_sel    = cfg_rx_sel; // 2026-10-21: 25MHz 域原样透出
	assign o_dual_en    = cfg_dual_en;
	assign o_mark_en    = cfg_mark_en;
	assign o_dual_start = cfg_dual_start;
	// ⚠ 2026-10-21 修: 这里原来重复写了一行 `assign o_rx_sel = cfg_rx_sel;`，
	//   同一个 wire 两个驱动 -> 综合后 o_rx_sel 可能被优化掉/取错值 ->
	//   S_rx_sel 恒 0 -> 时钟 mux 永远选 cam0(没插的) -> S_hs_rx_clk 停摆 ->
	//   整个写侧不工作, RK 端只能反复读 DDR 里同一帧(画面冻结)。已删重复行。

	//-------------------------------------------------------------------------
	// I2C 从机
	//-------------------------------------------------------------------------
	i2c_slave #(.DEV_ADDR(DEV_ADDR)) u_i2c (
		.clk       (i_sys_clk),
		.rst_n     (sys_rst_n),
		.scl_i     (i_scl),
		.sda_i     (i_sda),
		.sda_drive (o_sda_drive),
		.o_wr_en   (wr_en),
		.o_wr_addr (wr_addr),
		.o_wr_data (wr_data),
		.o_rd_addr (rd_addr),
		.i_rd_data (rd_data),
		.o_dbg_state  (),
		.o_dbg_wr_cnt (),
		.o_dbg_rd_cnt ()
	);

	//-------------------------------------------------------------------------
	// 帧计数 (像素域) + 同步回系统域
	//  V36: 原来的 i_frame_tuser (=S_ISP_O_tuser) 实测恒为 0, 计数器 0xB8 一直是 0,
	//       害得我们无法判定"传感器只给 12.5fps"还是"FPGA 只吐 12.5fps"。
	//       现在改成两个一定存在的信号:
	//         0xB8..0xBB <-- CSI-2 FS 短包计数 = 传感器真实帧率 (最关键的数)
	//         0xD0/0xD1  <-- ui_image_correction 输出帧计数(低16位, 会回转)
	//       另存一个行计数 cnt_line_pix, 当前未引出, 留着以后用。
	//      (声明已提前到 jpeg_regfile 例化之前, 见上面 V37 注释)
	//-------------------------------------------------------------------------

	always @(posedge i_pix_clk or negedge i_pix_rst_n) begin
		if (!i_pix_rst_n) begin
			cnt_csi_pix  <= 32'd0;
			cnt_corr_pix <= 32'd0;
			cnt_line_pix <= 32'd0;
		end else begin
			if (i_fs_csi)     cnt_csi_pix  <= cnt_csi_pix  + 32'd1;
			if (i_fs_corr)    cnt_corr_pix <= cnt_corr_pix + 32'd1;
			if (i_last_corr)  cnt_line_pix <= cnt_line_pix + 32'd1;
		end
	end

	always @(posedge i_sys_clk or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			cnt_s1 <= 32'd0; cnt_s2 <= 32'd0;
			csi_t1 <= 32'd0; csi_t2 <= 32'd0;
			corr_t1 <= 32'd0; corr_t2 <= 32'd0;
			line_t1 <= 32'd0; line_t2 <= 32'd0;
		end else begin
			csi_t1  <= cnt_csi_pix;  csi_t2  <= csi_t1;
			corr_t1 <= cnt_corr_pix; corr_t2 <= corr_t1;
			line_t1 <= cnt_line_pix; line_t2 <= line_t1;
			cnt_s1  <= csi_t2;       cnt_s2  <= cnt_s1;
		end
	end

	//-------------------------------------------------------------------------
	// 配置信号: 系统域 -> 像素域 (2 级同步)
	//-------------------------------------------------------------------------
	reg [3:0] mode_s1, mode_s2;
	reg [4:0] sh_s1,   sh_s2;
	reg [7:0] th_s1,   th_s2;
	reg       ms_s1,   ms_s2;
	// V45 高级新增参数
	reg [7:0] mth_s1,  mth_s2;
	reg [4:0] lap_s1,  lap_s2;
	reg [4:0] pre_s1,  pre_s2;
	reg [3:0] embg_s1, embg_s2;
	reg [7:0] embb_s1, embb_s2;

	// V45 初级
	reg [4:0] ben_s1,  ben_s2;
	reg       bgm_s1,  bgm_s2;
	reg [3:0] bga_s1,  bga_s2;
	reg [1:0] bkr_s1,  bkr_s2;
	reg [7:0] bhe_s1,  bhe_s2;
	reg [7:0] bhc_s1,  bhc_s2;
	reg       blf_s1,  blf_s2;
	reg [3:0] bct_s1,  bct_s2;
	reg [7:0] wbr_s1,  wbr_s2;
	reg [7:0] wbb_s1,  wbb_s2;
	reg [6:0] roi_s1,  roi_s2;
	reg [2:0] fps_s1,  fps_s2;
	// bsel_s1/bsel_s2 的声明已上提到 cfg_* 那一节 (o_bayer_sel 的 assign 更早)

	always @(posedge i_pix_clk or negedge i_pix_rst_n) begin
		if (!i_pix_rst_n) begin
			mode_s1 <= 4'd0; mode_s2 <= 4'd0;
			sh_s1 <= 5'd8;   sh_s2 <= 5'd8;
			th_s1 <= 8'd128; th_s2 <= 8'd128;
			ms_s1 <= 1'b1;   ms_s2 <= 1'b1;
			mth_s1<= 8'd128; mth_s2<= 8'd128;
			lap_s1<= 5'd8;   lap_s2<= 5'd8;
			pre_s1<= 5'd8;   pre_s2<= 5'd8;
			embg_s1 <= 4'd4; embg_s2 <= 4'd4;
			embb_s1 <= 8'd128; embb_s2 <= 8'd128;
			ben_s1<= 5'd0;   ben_s2<= 5'd0;
			bgm_s1<= 1'b0;   bgm_s2<= 1'b0;
			bga_s1<= 4'd8;   bga_s2<= 4'd8;
			bkr_s1<= 2'd1;   bkr_s2<= 2'd1;
			bhe_s1<= 8'd255; bhe_s2<= 8'd255;
			bhc_s1<= 8'd255; bhc_s2<= 8'd255;
			blf_s1<= 1'b0;   blf_s2<= 1'b0;
			bct_s1<= 4'd4;   bct_s2<= 4'd4;
			wbr_s1 <= 8'd128; wbr_s2 <= 8'd128;
			wbb_s1 <= 8'd128; wbb_s2 <= 8'd128;
			roi_s1 <= 7'd100; roi_s2 <= 7'd100;
			fps_s1 <= 3'd1;   fps_s2 <= 3'd1;
			bsel_s1 <= 2'd0;  bsel_s2 <= 2'd0;
		end else begin
			mode_s1 <= cfg_pp_mode; mode_s2 <= mode_s1;
			sh_s1   <= cfg_pp_sh;   sh_s2   <= sh_s1;
			th_s1   <= cfg_pp_th;   th_s2   <= th_s1;
			ms_s1   <= cfg_pp_ms;   ms_s2   <= ms_s1;
			mth_s1  <= cfg_pp_morph_th;  mth_s2  <= mth_s1;
			lap_s1  <= cfg_pp_lap_sh;    lap_s2  <= lap_s1;
			pre_s1  <= cfg_pp_prew_sh;   pre_s2  <= pre_s1;
			embg_s1 <= cfg_pp_emboss_gain; embg_s2 <= embg_s1;
			embb_s1 <= cfg_pp_emboss_bias; embb_s2 <= embb_s1;
			ben_s1  <= cfg_basic_en;      ben_s2  <= ben_s1;
			bgm_s1  <= cfg_basic_gray;    bgm_s2  <= bgm_s1;
			bga_s1  <= cfg_basic_gauss;   bga_s2  <= bga_s1;
			bkr_s1  <= cfg_basic_ker;     bkr_s2  <= bkr_s1;
			bhe_s1  <= cfg_basic_he;      bhe_s2  <= bhe_s1;
			bhc_s1  <= cfg_basic_he_clip; bhc_s2  <= bhc_s1;
			blf_s1  <= cfg_basic_linefix; blf_s2  <= blf_s1;
			bct_s1  <= cfg_basic_contrast;bct_s2  <= bct_s1;
			// 这几个是慢变参数 (人手改的), 2 级同步足够;
			// 注意多比特跨域本应加握手, 但它们在“使用时”已经稳定了几十万个
			// 像素时钟, 不存在采样到中间态的实际窗口。
			wbr_s1  <= cfg_wb_r;    wbr_s2  <= wbr_s1;
			wbb_s1  <= cfg_wb_b;    wbb_s2  <= wbb_s1;
			roi_s1  <= cfg_roi_pct; roi_s2  <= roi_s1;
			fps_s1  <= cfg_fps_div; fps_s2  <= fps_s1;
			bsel_s1 <= cfg_bayer_sel; bsel_s2 <= bsel_s1;   // 2026-10-21
		end
	end

	// V39: RES_MODE 之前是"直接透传"，25MHz 寄存器直接进 147.5MHz 的 VTC/裁剪/
	//      dbuf 尺寸组合逻辑，是 STA 里 sys_clk -> clk4 的最差路径 (-4.949ns)。
	//      现在在像素域做 2 级同步，顶层拿到的 S_res_mode 已经是像素域寄存器；
	//      模式切换仍由 500ms 复位窗兜底。
	reg [1:0] res_mode_s1, res_mode_s2;
	always @(posedge i_pix_clk or negedge i_pix_rst_n) begin
		if (!i_pix_rst_n) begin
			res_mode_s1 <= 2'd0;
			res_mode_s2 <= 2'd0;
		end else begin
			res_mode_s1 <= cfg_res_mode;
			res_mode_s2 <= res_mode_s1;
		end
	end

	assign o_pp_mode        = mode_s2;
	assign o_pp_sobel_gain = sh_s2;
	assign o_pp_thresh      = th_s2;
	assign o_pp_morph_sel   = ms_s2;
	assign o_pp_morph_th    = mth_s2;
	assign o_pp_lap_gain   = lap_s2;
	assign o_pp_prew_gain  = pre_s2;
	assign o_pp_emboss_gain = embg_s2;
	assign o_pp_emboss_bias = embb_s2;

	assign o_basic_en       = ben_s2;
	assign o_basic_gray     = bgm_s2;
	assign o_basic_gauss    = bga_s2;
	assign o_basic_ker      = bkr_s2;
	assign o_basic_he       = bhe_s2;
	assign o_basic_he_clip  = bhc_s2;
	assign o_basic_linefix  = blf_s2;
	assign o_basic_contrast = bct_s2;

	assign o_wb_r    = wbr_s2;
	assign o_wb_b    = wbb_s2;
	// V21 诊断: i_line_groups 来自 S_hs_rx_clk 域, 2 级同步到 i_sys_clk 后取历史最大值。
	// 取最大值可自动滤掉跨时钟采样时可能出现的瞬时撕裂值, 读数稳定。
	// V39: 切模式时清空 400ms，避免 0xD4/0xD5 保留上一个模式的 966，
	//      导致切回 1080p 后仍显示 966。
	reg [23:0] lg_blank;
	always @(posedge i_sys_clk or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			lg_s1 <= 16'd0; lg_s2 <= 16'd0; lg_max <= 16'd0; lg_blank <= 24'd0;
		end else begin
			lg_s1 <= i_line_groups;
			lg_s2 <= lg_s1;
			// 400ms @25MHz：覆盖 D-PHY RX 复位(约 250ms)+传感器全表重写，
			// 否则 RX 时钟停住期间 i_line_groups 会冻结在旧模式的 966。
			if (cfg_res_chg)          lg_blank <= 24'd10_000_000;
			else if (lg_blank != 0)   lg_blank <= lg_blank - 24'd1;

			if (cfg_res_chg || lg_blank != 0)
				lg_max <= 16'd0;
			else if (lg_s2 > lg_max)
				lg_max <= lg_s2;
		end
	end

	assign o_roi_pct = roi_s2;
	assign o_fps_div = fps_s2;
	// V39: 使用像素域 2 级同步后的 mode (见上面的 res_mode_s1/s2)
	assign o_res_mode = res_mode_s2;
	assign o_res_chg  = cfg_res_chg;

	// 摄像头参数仍在 25MHz 域 (cam_param 也挂这个域), 不用同步
	assign o_cam_exp  = cfg_cam_exp;
	assign o_cam_gain = cfg_cam_gain;
	assign o_cam_ev   = cfg_cam_ev;
	assign o_cam_trig = cfg_cam_trig;

endmodule
