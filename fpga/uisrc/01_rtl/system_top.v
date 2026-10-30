`timescale 1ns/1ns
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2025/12/10
*Module Name:
*File Name:
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.0
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_system internal signal
*5) n_ activ low
*6) dg_ debug signal
*7) r_ delay or register
*8) s_ state mechine
*********************************************************************/
/*********system_top***********
-- 异构视频链路测试工程: FPGA 采集 -> MIPI x4 高速送 RK3576 -> RK 端 HDMI 输出
--
-- 数据流:
--   IMX415 摄像头
--     -> MIPI CSI-2 RX (4 lane, 不用 LP) : mipi_csi_rx (uisrc/03_ip/mipi_csi_lpfree)
--                                           2026-10-20 子卡去 LP 抽头后由原
--                                           mipi_dphy_rx_over_lvds_wrapper 换过来
--     -> CSI-2 解包 + RAW10 还原          : 已并入 mipi_csi_rx (直接输出 40bit RAW10)
--     -> 图像裁剪                         : ui_image_correction
--     -> 米联客 ISP (BLC/AWB/Demosaic..)  : ui_isp_top  (输出 RGB888 x4 = 128bit)
--     -> RGB888 转 YUV422 (4 像素/拍)      : rgb_to_yuv422_quad
--     -> DDR 三帧缓存 (16bpp 写 / 32b 读)  : ui_dbuf + ui_FDMA + DDR3
--     -> 读侧按 VTC 时序读出              : ui_vtc
--     -> 32b/2px -> 64b/4px 跨时钟域      : yuv32_to_quad
--     -> 4 引擎并行 JPEG (16x8 MCU)        : jpeg_enc_if x4 + jpeg_encoder_top x4
--     -> 4 段码流 4:1 合并                 : jpeg_seg_merge4
--     -> 字节流跨时钟桥                    : jpeg_byte_bridge
--     -> CSI-2 变长帧/包组包 (DT=0x1E)     : csi2_frame_tx_var
--     -> D-PHY TX (4 lane HS + LP)        : mipi_dphy_tx_wrapper
--     -> RK3576 CSI3 (csi2_dphy3 / mipi3_csi2)
--     -> RK 端 milianke_mipi 驱动 -> CIF -> 用户态直接推流
--     -> HDMI 2.1 / 网页显示
--
-- ★★★ 2026-10-28 V51: NV16 已移除, MIPI 只输出 JPEG ★★★
--   为什么: NV16 3840x1080@60 = 498MB/s, 4lane@1000Mbps 只有 500MB/s
--   (99.6%), 且每行 2123 byte_clk @125MHz = 16.96us 超过 VTC 的 14.91us
--   行预算 13.7% -> 必然截包 -> CRC 满屏。结构上不可能, 不是 bug。
--   所以:
--     - csi2_pack_yuv422_stream / csi2_frame_tx(定长) / csi2_test_src
--       / 读侧帧标记注入 / TX_SRC_SEL mux 全部删除;
--     - 0x0B[0] JPG_TX 锁死 1, 0x0B[1] DT18 锁死 0, 0x0B[2] JPAD 默认 0。
--
-- 关键点:
--   1) 内容固定是硬件 JPEG 码流 (变长帧), 但 CSI-2 的 DT 仍是 0x1E ——
--      rkcif 没有 JPEG 支持, 只能当 YUV422 字节流收。驱动继续上报
--      MEDIA_BUS_FMT_YUYV8_2X8, 应用层扫 FF D8..FF D9 取帧。
--   2) I_dsi_en 由 RK 侧 (dts 里 mipi-en-gpios = gpio1 RK_PD0) 驱动,
--      高电平才使能 D-PHY 发送; 驱动的 s_stream() 打开流时置高。
--      它同时是 csi2_frame_tx_var 的 enable —— D-PHY 复位期间不往乒乓里塞包。
*********************************************************************/

`define DRAM_BYTE_NUM 2   	   // 1 = x8, 2 = x16,4 = x32,8=x64
`define DRAM_SIZE    "2G"     // AP106,AP102=2G ,AP104=4G    1G , 2G , 4G = 256x16bit, 8G    ,ONE DDR particle capacity

//`define XLNX_NATIVE
//`define ALC_NATIVE  
`define MC_AXI  
 
//`define AXI_ATG  
//`define ATG   
//`define DFI
  
module system_top#(
parameter DRAM_TYPE       = "DDR3"  ,            //"DDR4" "DDR3"
parameter ECC             = "OFF",
parameter APP_ADDR_WIDTH  = (`DRAM_SIZE=="1G")?26:(`DRAM_SIZE=="2G")?27:(`DRAM_SIZE == "4G")?28:(`DRAM_SIZE == "8G")?29:28, //512Mx16bit=29 ,256Mx16bit=28 ,128Mx16bit=27,64Mx16bit = 26,
parameter AXI_ID_WIDTH    =  4,                                                                                   
parameter APP_DATA_WIDTH  = (ECC == "ON")? (`DRAM_BYTE_NUM-1)*8*8 : `DRAM_BYTE_NUM*8*8,
parameter APP_MASK_WIDTH  = (ECC == "ON")? (`DRAM_BYTE_NUM-1)*8   : `DRAM_BYTE_NUM*8,
parameter AXI_ADDR_WIDTH  = APP_ADDR_WIDTH+3,
parameter AXI_DATA_WIDTH  = APP_DATA_WIDTH,
parameter DQ_WIDTH        = `DRAM_BYTE_NUM * 8,
parameter DQS_WIDTH       = `DRAM_BYTE_NUM,
parameter DM_WIDTH        = `DRAM_BYTE_NUM,
parameter ADDR_WIDTH      = (DRAM_TYPE=="DDR4")?17:(`DRAM_SIZE=="1G")?13:(`DRAM_SIZE=="2G")?14:(`DRAM_SIZE == "4G")?15:(`DRAM_SIZE == "8G")?16:15, // 512Mx16bit=16 ,256Mx16bit=15,128Mx16bit=14,64Mx16bit=13
parameter ROW_WIDTH       = (`DRAM_SIZE=="1G")?13:(`DRAM_SIZE=="2G")?14:(`DRAM_SIZE == "4G")?15:(`DRAM_SIZE == "8G")?16:15,                        // 512Mx16bit=16 ,256Mx16bit=15,128Mx16bit=14,64Mx16bit=13
parameter COL_WIDTH       = 10,                  
parameter BA_WIDTH        = 3,                   
parameter BG_WIDTH        = 1,                   
parameter ODT_WIDTH       = 1,                   
parameter CKE_WIDTH       = 1,                   
parameter CS_WIDTH        = 1                    
)
(
    input                           I_sysclk_25m,	//系统时钟
    input                           I_ddr_clk   ,	//DDR参考时钟
	
	//DDR
    output    [ADDR_WIDTH-1:0]      ddr_addr    , 
    output    [  BA_WIDTH-1:0]      ddr_ba      ,
    output    [ CKE_WIDTH-1:0]      ddr_cke     ,
    output    [ ODT_WIDTH-1:0]      ddr_odt     ,
    output    [  CS_WIDTH-1:0]      ddr_cs_n    ,
    output                          ddr_ras_n   ,
    output                          ddr_cas_n   ,
    output                          ddr_we_n    ,
    output                          ddr_ck_p    ,
    output                          ddr_ck_n    ,
    output                          ddr_reset_n ,
    inout     [  DM_WIDTH-1:0]      ddr_dm  	,
    inout     [  DQ_WIDTH-1:0]      ddr_dq      ,
    inout     [ DQS_WIDTH-1:0]      ddr_dqs_n   ,
    inout     [ DQS_WIDTH-1:0]      ddr_dqs_p   ,

	//摄像头配置信号 (cam0 = 子卡 J2 / CSI 座)
	output wire 					O_clk_24m	,	//摄像头工作时钟 (A18)
	output wire 					O_clk_rst	,	//摄像头复位信号,默认上拉 (B18)
    output wire 					O_cam_scl	,   //I2C总线，SCL时钟 (B14)
    inout  wire 					IO_cam_sda	,   //I2C总线，SDA数据 (A14)
	//摄像头配置信号 (cam1 = 子卡 J3 / 原 DSI 座)
	//  2026-10-21 双路: 引脚全部来自子卡原理图 docs/MLK_FMC_MIPI_250530.pdf
	//    P03_MIPITX: J3 pin 8 = DSI_CLK(=MCLK, 串 R91 22R), pin 4 = DSI_RSTN
	//               pin 35 = DSI_IIC_SDA, pin 38 = DSI_IIC_SCL
	//    P01_CON   : LA28_P->DSI_CLK(FPGA J13) LA28_N->DSI_RSTN(K13)
	//               LA32_P->DSI_IIC_SDA(N11) LA32_N->DSI_IIC_SCL(N10)
	output wire 					O_clk_24m_1,	//cam1 工作时钟 (J13 = LA28_P)
	output wire 					O_clk_rst_1,	//cam1 复位信号,恒高 (K13 = LA28_N)
	output wire 					O_cam_scl_1,	//cam1 SCCB SCL (N10 = LA32_N)
	inout  wire 					IO_cam_sda_1,   //cam1 SCCB SDA (N11 = LA32_P)
	//参数通道 I2C (FPGA 从机, 地址 0x40)
	//引脚 = L18/M18: 手册 CON1C 表显示它们与 RK 的 I2C9 (B27/A28) 同网,
	//厂商设备树 AFH03/csi-imx415-2.dtsi 里也把 FPGA 定义成 i2c9 上的从机,
	//所以**不需要飞线**。地址避开厂商 DTS 里的 0x1a (已被内核驱动占用)。
	//从机不做时钟拉伸, 所以 SCL 只读不驱动。
	inout  wire 					IO_cfg_scl	,   //参数通道 SCL (L18)
	inout  wire 					IO_cfg_sda	,   //参数通道 SDA (M18)
	// I_button 口已删除: U17/V17 LVDS 对被 DSI HS data lane[1] 占用, 本工程不再外提按键
	
	//MIPI_RX
	//  2026-10-20: 子卡去掉 LP 抽头后, 物理上只剩 5 对差分 (CLK + D0~D3)。
	//  按厂家说法「改引脚定义后用 LVDS 解 MIPI」: 这里不再提 I_data_lp_p/n,
	//  改由 mipi_csi_rx 用 LVDS + IDELAY/IDDR 解串 (靠 CSI-2 包头同步, 不需要 LP)。
	input  wire		    			I_clk_hs_p  ,	
	input  wire	[3:0]				I_data_hs_p , 
	
	//MIPI_RX #1 (cam1, 子卡 J3 / 原 DSI 座)
	//  5 对差分 (子卡 P01_CON 直连表):
	//    HS_CLK = FMC CLK1_M2C -> E16 / F16
	//    HS_D0  = FMC LA29      -> F18 / G18
	//    HS_D1  = FMC LA31      -> K16 / K17
	//    HS_D2  = FMC LA30      -> D17 / E17
	//    HS_D3  = FMC LA33      -> J17 / J18
	//  ⚠ 手册「CSI 连接器表」里把这 4 条 Dx 写成了 LA22/LA25/LA29/LA31，是错的。
	//    LA22/LA25 在子卡上接的是 DSI_LP_CKP/N 和 DSI_LP_D2P/N，不是 HS 数据。
	input  wire		    			I_clk1_hs_p ,	
	input  wire	[3:0]				I_data1_hs_p, 
	
	input  wire						I_dsi_en			,	//RK3576 高表示使能 DSI 发送
	output wire						O_mipi_dsi_hs_clk_p	,
	output wire	[3:0]				O_mipi_dsi_hs_data_p,
	output wire						O_mipi_dsi_lp_clk_p	,
	output wire						O_mipi_dsi_lp_clk_n	,
	output wire	[3:0]				O_mipi_dsi_lp_data_p,
	output wire	[3:0]				O_mipi_dsi_lp_data_n
);

	//==================== 视频格式 / 分辨率配置 ====================
	// 只需改这两个常量即可切换输出分辨率 (同时必须同步修改:
	//   1. RK 端驱动的 DUMMY_WIDTH / DUMMY_HEIGHT
	//   2. 本节所有 ui_dbuf / ui_vtc / csi2_* 的派生参数已自动跟随)
	localparam integer H_ACTIVE = 1920;   // 有效像素/行
	localparam integer V_ACTIVE = 1080;   // 有效行数

	// ui_dbuf 读/写通道的 AXI 突发长度 (beat 数), 由像素位宽推导:
	//   写侧 64bit/beat = 4 像素 YUV422 (16bpp)  -> H_ACTIVE/4
	//   读侧 32bit/beat = 2 像素 YUV422 (16bpp)  -> H_ACTIVE/2
	localparam integer W_BEATS_PER_LINE = H_ACTIVE / 4;
	localparam integer R_BEATS_PER_LINE = H_ACTIVE / 2;

	// 1080P60 标准时序 (像素时钟 148.5MHz 下的行/场参数)
	localparam integer H_SA = 44, H_BP = 148, H_FP = 88;
	localparam integer V_SA = 5 , V_BP = 36 , V_FP = 4 ;

	// ==== V21: 运行时分辨率参数 ======================================
	//  由 cfg_ctrl_top 的 RES_MODE 寄存器 (0xE0) 选择:
	//     2'd0 = 1920x1080@60  (默认, 与改动前完全一致)
	//     2'd1 = 3840x2160@30   (497.7 MB/s = 99.5% 带宽, 物理上跑不动, 仅保留)
	//     2'd2 = 3840x2160@25   (414.7 MB/s = 82.9%, **4K 实际可用档**)
	//  ★ 必须区分两类尺寸:
	//     S_h_active / S_v_active = "图像宽高" —— 给 ui_image_correction 的裁剪边界、
	//        ISP 行缓冲、preproc 行宽、csi2_pack/Frame_tx 用。
	//     S_vtc_*                 = "VTC 读取时序" —— 只控制 dbuf 读侧每秒放多少数据。
	//  1080p 下两者恰好都是 1920; 4K 下图像是 3840, 但 VTC 的 de 窗口只需
	//  >= R_BEATS(1920) 个字节时钟 —— 所以仍取 1920。这就是两者必须分开的原因。
	wire [1:0]  S_res_mode;                          // 由 cfg_ctrl_top 驱动
	wire [1:0]  S_bayer_sel;                         // 2026-10-21: 0xDA Bayer 相位
	wire        S_res_chg;                           // 模式写入脉冲 (25MHz 域)
	wire        S_res_rstn;                          // 模式切换复位窗 (S_pclkx1 域)
	wire [15:0] S_line_groups;                       // V21 诊断: 每行像素组数

	// 4K 模式 (2'd1/@30 与 2'd2/@25) 的图像尺寸完全相同, 只有 VTC 场周期不同
	// ★ 2026-10-28: 双目拼接成为**唯一**工作模式 (作品只要求 1080p@60 双目), 4K 废弃。
	//   图像宽 = 3840 = 左半(cam1) + 右半(cam0), 高 = 1080。
	//   crop 模块仍按单目 1920 裁, 所以 S_cam_h 与 S_h_active 必须分开。
	wire        S_is_4k        = 1'b0;

	// ---- 图像宽高 ----
	wire [12:0] S_cam_h        = 13'd1920;          // 单目裁剪宽度 (ui_image_correction 用)
	wire [12:0] S_h_active     = 13'd3840;          // 拼接后整行 (ISP/preproc/dbuf/编码器用)
	wire [11:0] S_v_active     = 12'd1080;
	wire [15:0] S_w_beats      = 16'd960;           // 64b/beat = 4px -> 3840/4
	wire [15:0] S_r_beats      = 16'd1920;          // 32b/beat = 2px -> 3840/2
	// V39: 传感器垂直裁剪起点。4K 录制区从第 36 行开始 (厂商 v_start=35)；
	//      1080p 厂商参考 v_start=19。首行必须是偶数，否则 RGGB Bayer 相位错。
	wire [12:0] S_v_start      = S_is_4k ? 13'd35  : 13'd19;

	// 2026-10-21: 每行**实际**像素组数(含尾部被裁掉的部分)。
	//   ⚠ 0x4704 起**强制传 0**，退回"行间空闲 10 拍才分行"的原判据。
	//
	//   历史: 0x4703 曾传 486/966 做「固定行宽分行」，理由是"cam1 的 valid
	//   在行间不会掉，空闲判据永不触发"。**那个理由是错的** —— 当时 E4/E6
	//   读数恒 0, 被误读成"分行失败"；真实原因是切 CSI 源后 D-PHY RX 的
	//   AXIS 输出状态机被冻住、tlast 再也不出（见 S_src_rx_rst 那段注释）。
	//   修好换源复位之后，cam1 单目本来就是靠空闲判据正常工作过的，
	//   硬塞一个固定 486 反而在元组数不等于 486 时把行切错。
	//   ui_image_correction 里 grp_pl==0 就走原路径，端口留着便于以后再试。
	wire [12:0] S_grp_per_line = 13'd0;

	// ---- VTC 读取时序 (S_pclkx1 = 147.5MHz) ----
	//  帧率 = 147.5e6 / (H_FrameSize * V_FrameSize)
	//    1080p60: 2200 * 1125 = 2.475e6 -> 59.6 fps  (实测 59.4)
	//    4K30   : 2652 * 2387 = 6.330e6 -> 23.3 fps  (受 1000Mbps TX 带宽限制)
	//    4K25   : 2652 * 2225 = 5.901e6 -> 24.997 fps (82.9% 带宽, 可用)
	//  H_ActiveSize/SyncStart/SyncEnd 两种模式相同, 帧长只靠 H_FrameSize 调。
	//  注: Verilog 不允许对括号表达式做位选 ((a+b)[12:0] 是语法错误), 靠 wire 位宽截断。
	wire [12:0] S_vtc_h_active = H_ACTIVE[12:0];                            // 1920
	wire [12:0] S_vtc_h_start  = H_ACTIVE + H_FP;                           // 2008
	wire [12:0] S_vtc_h_end    = H_ACTIVE + H_FP + H_SA;                    // 2052
	// V38e: 4K25 —— h_frame 与 v_frame 必须同时满足两个约束:
	//   (a) 每行预算 = h_frame/147.5MHz 要 >= TX 的 16.98us
	//       (1920 payload + 200 GAP_LINE + 3 = 2123 byte_clk @125MHz)
	//       => h_frame >= 2504
	//   (b) 帧率 = 147.5MHz/(h_frame x v_frame) = 25fps
	//       => h_frame x v_frame = 5,900,000
	//   取 2652 x 2225 = 5,900,700:
	//       帧率     = 24.997 fps
	//       每行预算 = 2652/147.5M = 17.98us  (余量 5.9%)
	//       场消隐   = (2225-2160) x 17.98us = 1168us  (RK 要求 >=1000us ✅)
	//       且 v_end(2169) < v_frame(2225) ✅
	wire [12:0] S_vtc_h_frame  = S_is_4k ? 13'd2652
	                                     : (H_ACTIVE+H_FP+H_SA+H_BP);   // 4K:2652 FHD:2200
	wire [11:0] S_vtc_v_active = S_is_4k ? 12'd2160 : V_ACTIVE[11:0];
	wire [11:0] S_vtc_v_start  = S_is_4k ? 12'd2164 : (V_ACTIVE+V_FP);
	wire [11:0] S_vtc_v_end    = S_is_4k ? 12'd2169 : (V_ACTIVE+V_FP+V_SA);
	// 4K 场周期: 已废弃 (拼接模式只用 1080 行时序)
	wire [11:0] S_vtc_v_frame  = (V_ACTIVE+V_FP+V_SA+V_BP);   // 1125 -> 59.6fps
	//===============================================================
                                      

//-------- User Clock --------//
wire                       		S_dfi_clk             ;
wire                       		S_ddr_init_cal_done   ;

// AXI Write Addr
wire [AXI_ADDR_WIDTH-1:0]      	S_axi_awaddr  	;
wire                           	S_axi_awvalid 	;
wire                           	S_axi_awready 	;
wire   [AXI_ID_WIDTH-1:0]      	S_axi_awid    	;
wire                [7:0]      	S_axi_awlen   	; 
wire                [2:0]      	S_axi_awsize  	; 
wire                [1:0]      	S_axi_awburst 	; 
wire                [0:0]      	S_axi_awlock  	; 
wire                [3:0]      	S_axi_awcache 	; 
wire                [2:0]      	S_axi_awprot  	; 
wire                [3:0]      	S_axi_awqos   	;
// AXI Write Data              		
wire [APP_DATA_WIDTH-1:0]      	S_axi_wdata   	;
wire [APP_MASK_WIDTH-1:0]      	S_axi_wstrb   	;
wire                           	S_axi_wvalid  	;
wire                           	S_axi_wlast   	;
wire                           	S_axi_wready  	;
// Write Response Port         		
wire   [AXI_ID_WIDTH-1:0]      	S_axi_bid     	;    
wire                [1:0]      	S_axi_bresp   	;    
wire                           	S_axi_bvalid  	;    
wire                           	S_axi_bready  	;    
								
// AXI Read Addr               	
wire [AXI_ADDR_WIDTH-1:0]      	S_axi_araddr  	;
wire                           	S_axi_arvalid 	;
wire                           	S_axi_arready 	;
wire [  AXI_ID_WIDTH-1:0]      	S_axi_arid    	;
wire                [7:0]      	S_axi_arlen   	;
wire                [2:0]      	S_axi_arsize  	;
wire                [1:0]      	S_axi_arburst 	;
wire                [0:0]      	S_axi_arlock  	;
wire                [3:0]      	S_axi_arcache 	;
wire                [2:0]      	S_axi_arprot  	;
wire                [3:0]      	S_axi_arqos   	;
// AXI Read Data               		
wire [APP_DATA_WIDTH-1:0]      	S_axi_rdata   	;
wire                           	S_axi_rlast   	;
wire                           	S_axi_rvalid  	;
wire                           	S_axi_rready  	;
wire   [AXI_ID_WIDTH-1:0]      	S_axi_rid     	;
wire                [1:0]      	S_axi_rresp   	;

//MLK_FDMA
wire [AXI_ADDR_WIDTH-1:  0]    	S_fdma_waddr	;   //FDMA写通道地址
wire                           	S_fdma_wareq	;   //FDMA写通道请求
wire [15: 0]                   	S_fdma_wsize	;   //FDMA写通道一次FDMA的传输大小                                       
wire                           	S_fdma_wbusy	;   //FDMA处于BUSY状态，AXI总线正在写操作 		
wire [AXI_DATA_WIDTH-1 : 0]    	S_fdma_wdata	;   //FDMA写数据
wire                           	S_fdma_wvalid	;   //FDMA 写有效
wire                           	S_fdma_wready	;   //FDMA写准备好，用户可以写数据
								
wire [AXI_ADDR_WIDTH-1:  0]    	S_fdma_raddr	;   //FDMA读通道地址
wire                           	S_fdma_rareq	;   //FDMA读通道请求
wire [15: 0]                   	S_fdma_rsize	;   //FDMA读通道一次FDMA的传输大小                                       
wire                           	S_fdma_rbusy	;   //FDMA处于BUSY状态，AXI总线正在读操作 			
wire [AXI_DATA_WIDTH-1 : 0]    	S_fdma_rdata	;   //FDMA读数据
wire                           	S_fdma_rvalid	;   //FDMA 读有效
wire                           	S_fdma_rready	;   //FDMA读准备好，用户可以读数据	
wire                           	S_test_error	;   //测试是否有错误，1有错误，0没错误

wire   							S_clk_24m		;
wire        					S_pclkx1		;
wire        					S_pclkx5		;
wire        					S_clk_70m		;
wire        					S_pll_lock		;

	//---- DSI PLL outputs (sourced from I_sysclk_25m) ----
	wire							S_dsi_25m_unused;
	wire							S_dsi_byte_clk	;	// ★125MHz (VCO1000/8; 原注释写 75MHz 是错的)
	wire							S_dsi_hs_x2		;	// 150MHz -> wrapper I_hs_clk_x2
	wire							S_dsi_hs_x4		;	// 300MHz -> wrapper I_hs_clk_x4
	wire							S_dsi_hs_x4_90d	;	// 300MHz @90 -> wrapper I_hs_clk_x4_90d
	wire							S_dsi_lp_clk	;	// 10MHz  -> wrapper I_lpdt_clk
	wire							S_dsi_pll_lock	;

	//---- ui_dbuf R-side AXIS hookups for DSI chain ----
	wire							S_dsi_R_tuser	;
	wire							S_dsi_R_tvalid	;
	wire							S_dsi_R_tlast	;
	// ★ V51: S_dsi_R_tdata32 (NV16 用的 32bit word + 帧标记注入) 和
	//   S_dsi_pack_tready 已随 NV16 通路删除。dbuf 读侧现在只喂 yuv32_to_quad。

	//---- DSI 握手同步 + 复位 ----
	reg  [1:0]						S_dsi_en_sync	= 2'b00;
	wire							S_dsi_en_int	= S_dsi_en_sync[1];
	wire							S_dphy_rst_n	= S_pll_lock & S_dsi_pll_lock & S_dsi_en_int;

wire [7:0]						S_ae			;
wire 							S_cam_cfg_done	;
wire 							S_ae_cfg_done	;
wire 							S_ae_req		;

//=============================================================================
//  2026-10-21 双路 CSI: 两个 mipi_csi_rx 实例 + 时钟/数据二选一
//
//  为什么必须两个实例（不能共用一个）：
//    TD 的 **SYN-8207**: IDDR/IDELAY 必须直连 PAD，端口与例化之间不能插 mux。
//    所以引脚切换只能在 PAD 之外做 —— 也就是先各自解出一路，再选。
//
//  时钟：
//    两路 RX 各自恢复出自己的 byte clock (S_hs_clk0 / S_hs_clk1)，
//    再经 LUT 二选一 + **显式 PH1_LOGIC_BUFG** 变回一个全局时钟网。
//    ★ 不做 BUFG 的话 S_ud_wclk (= S_hs_rx_clk) 会落在普通布线网上，
//      偏斜导致写侧丢拍 → 画面向上滚动 (0x450E 实测)。
//    ★ 两路 RX 的 m_axis_video_aclk 都接这个 BUFG 后的同一个网，
//      避免"同名不同网"。
//
//  源选择：
//    0xDB[0]: 0=cam0 (上电默认)  1=cam1
//    改动时 system_top 会给写侧一个 120ms 复位窗，让行/帧计数重新对齐。
//=============================================================================
wire          					S_hs_clk0		;   // cam0 RX 恢复时钟 (cam0 侧整条链用它)
wire          					S_hs_clk1		;   // cam1 RX 恢复时钟 (cam1 侧整条链用它)
wire                                            S_st_clk                ;   // ★ 拼接/下游像素域 = S_clk_70m = 73.75MHz (PLL C3, 20 分频; V54)
wire          					S_enc_clk		;   // JPEG 编码器时钟 (V47.14 起 = S_hs_rx_clk 70MHz)
wire          					S_hs_rx_clk		;   // 保留旧名: 下游像素域 (= S_st_clk)

	//---- LP-free CSI-2 RX (03_ip/mipi_csi_lpfree) 的 AXIS 输出 ----
	wire							S_rx_rstn		;
	wire [39:0]						S_rx_tdata		;
	wire							S_rx_tvalid		;
	wire							S_rx_tlast		;
	wire							S_rx_tuser		;
	// cam0 / cam1 各自（选源之前的）原始 AXIS
	wire [39:0]						S_rx0_tdata		;
	wire							S_rx0_tvalid	;
	wire							S_rx0_tlast		;
	wire							S_rx0_tuser		;
	wire [39:0]						S_rx1_tdata		;
	wire							S_rx1_tvalid	;
	wire							S_rx1_tlast		;
	wire							S_rx1_tuser		;

	//---- 选源 ----
	wire							S_rx_sel		;   // 25MHz 域 (0xDB[0])
	wire							S_src_chg		;   // 25MHz 单拍: 源变了
	reg 							S_rx_sel_d		;
	// 同步到 RX 时钟域后再用于数据 mux（同域组合，不引亚稳态）
	reg  [1:0]						S_rx_sel_rx_s	;
	wire							S_rx_sel_rx		;

	//---- 2026-10-21 双目交替 ----
	wire							S_dual_en		;   // 0xDB[1]
	wire							S_mark_en		;   // 0xDB[2] | dual
	wire							S_dual_start	;   // 写 0xDB 进双目时的一拍脉冲
	wire							S_dual_eff		;   // = dual_en & ~is_4k
	wire							S_out_src		;   // 当前输出帧的来源 0/1
	wire							S_frame_parity	;
	wire							S_ch1_lost		;   // cam1 行缓冲没跟上
	wire							S_sensor_rst_n	;   // 两颗传感器的 RSTn (同步启动)
	wire							S_cfg_hold		;   // 1 = 两个 cfg 模块保持在复位

	//---- 两路裁剪输出 ----
	wire [39:0]						S_crop0_tdata	;
	wire							S_crop0_tvalid	;
	wire							S_crop0_tlast	;
	wire							S_crop0_tuser	;
	wire							S_crop0_frame_start;
	wire [39:0]						S_crop1_tdata	;
	wire							S_crop1_tvalid	;
	wire							S_crop1_tlast	;
	wire							S_crop1_tuser	;
	wire							S_crop1_frame_start;
	wire [15:0]						S_line_groups1	;
	wire							S_res_rstn_rx1	;

	//---- cam1 的 RX 调试总线 ----
	wire [7:0]						S_rx1_dbg_mipi	;
	wire [7:0]						S_rx1_dbg_delay	;
	wire [5:0]						S_rx1_dbg_best_len;
	wire							S_rx1_autodone	;

	//---- RX 调试总线 (只读寄存器 0xD6/0xD7/0xD8) ----
	wire [7:0]						S_rx_dbg_mipi	;
	wire [7:0]						S_rx_dbg_delay	;
	wire [5:0]						S_rx_dbg_best_len;
	wire							S_rx_autodone	;

	wire        					S_csi_frame_start;   // 供 cfg_ctrl_top 统计传感器真实帧率

	
wire          					S_raw10_frame_start;
wire          					S_raw10_frame_end;
wire          					S_raw10_valid	;
wire [39 : 0] 					S_raw10_data	;

wire [39:0]						S_axis_tdata	;
wire 							S_axis_tvalid	;
wire 							S_axis_tlast	; 
wire 							S_axis_tuser	; 

wire							S_ISP_O_tready 	;
wire [127:0]					S_ISP_O_tdata  	;  // RGBX8888 ×4 真彩 (原 64b RGB565×4)
wire 							S_ISP_O_tlast  	;
wire 							S_ISP_O_tuser  	;
wire 							S_ISP_O_tvalid 	;

wire [7:0] 						S_wbuf_sync		;
wire [7:0] 						S_rbuf_sync		;
					
wire 							S_ud_wclk		;
wire 							S_ud_wtuser		; 
wire 							S_ud_wtvalid	; 
wire 							S_ud_wtlast		; 
wire 							S_ud_wtready	;  
wire [63:0] 					S_ud_wtdata		;  // YUV422 (YUYV-on-wire) ×4 入 dbuf 写侧 = 16bpp×4 = 64b


wire        S_yuv_de;
wire        S_yuv_sof;
wire        S_yuv_last;
wire [63:0] S_yuv_data;

wire 							S_vtc_vs		;
wire 							S_vtc_hs		;
wire 							S_vtc_de_valid	;
wire 							S_vtc_user		;
wire 							S_vtc_last      ;
					
wire [31:0] 					S_ud_rtdata		;  // RGBX8888 (1 像素/cyc) 出 dbuf 读侧
					
wire        					S_R_vrst		;

//=============================================================================
//  2026-10-21 画面冻结定位 (只读 0xE1~0xE6)
//  ⚠ 声明必须放在第一个使用点(cfg_ctrl_top 例化)之前, 否则隐式 1bit wire
//=============================================================================
reg  [7:0]  D_sof_cnt;      // S_yuv_sof 帧首计数 (进 dbuf 写侧的 sof)
reg  [7:0]  D_vs_cnt;       // S_vtc_vs 场同步计数
reg  [7:0]  D_tl_cnt;       // S_axis_tlast 行尾计数
reg  [7:0]  D_rxck_cnt = 8'd0;     // S_hs_rx_clk 自由计数 (证明时钟活着)
reg  [7:0]  D_c1ck_cnt = 8'd0;     // S_hs_clk1  自由计数 (证明 cam1 恢复时钟活着)
reg  [7:0]  D_rtv_cnt;      // S_rx1_tvalid 计数 (证明数据到了)
reg         S_clk_sel_r;    // 时钟 mux 选择(寄存)
reg  [7:0]  D_sof_s1, D_sof_s2;
reg  [7:0]  D_vs_s1,  D_vs_s2;
reg  [7:0]  D_wb_s1,  D_wb_s2;
reg  [7:0]  D_tl_s1,  D_tl_s2;
reg  [7:0]  D_rxck_s1, D_rxck_s2;
reg  [7:0]  D_c1ck_s1, D_c1ck_s2;
reg  [7:0]  D_rtv_s1,  D_rtv_s2;
reg  [15:0] D_lg1_s1, D_lg1_s2;   // cam1 每行组数
					
assign O_clk_rst				= S_sensor_rst_n;
// cam1 复位 (K13 = LA28_N = 子卡 DSI_RSTN -> J3 pin4)
//   两颗共用同一根复位，才能"同时释放、同时重跑初始化表"把帧相位拉到一起
assign O_clk_rst_1				= S_sensor_rst_n;
	
assign S_ud_wclk 				= S_hs_rx_clk	;
assign S_ud_wtuser 				= S_yuv_sof		;
assign S_ud_wtvalid 			= S_yuv_de		;
assign S_ud_wtlast 				= S_yuv_last	;
//=============================================================================
//  2026-10-21: 帧标记（双目模式下 web 靠它区分这一帧是 cam0 还是 cam1）
//
//  打在本帧第一个 64bit 组（= 头 4 个像素）上，只在 sof 那一拍覆盖。
//  rgb_to_yuv422_quad 的输出位序: {Cr3, Y3, Cb2, Y2, Cr1, Y1, Cb0, Y0}
//  所以三个 Y 字节被设为 magic，第 4 个 Y 字节带源号：
//      Y0=0xA5  Y1=0x5A  Y2=src(0x00/0x11)  Y3=0xFF   色度=0x80(中性)
//  RK 侧落到 NV16 后 Y 平面前 4 字节就是 0xA5 0x5A src 0xFF。
//  代价：每帧损失 4 个像素（左上角），肉眼不可见。
//=============================================================================
wire [63:0] S_frame_mark = { 8'h80, 8'hFF,
                              8'h80, S_out_src ? 8'h11 : 8'h00,
                              8'h80, 8'h5A,
                              8'h80, 8'hA5 };
assign S_ud_wtdata 				= (S_mark_en && S_yuv_sof) ? S_frame_mark : S_yuv_data;


//=============================================================================
//  预处理流水线输出 (P4/P5/P6 -> rgb_to_yuv422_quad)
//  ⚠ 必须声明在这里 —— 即在 u_rgb2yuv_quad 之前。Verilog 里信号若在
//    使用点之后才声明, 会被隐式推断成 1 bit wire, S_pp_tdata 会从 128 bit
//    塌成 1 bit (TD: HDL-7225 already implicitly declared)。
//=============================================================================
wire         S_pp_tvalid;
wire         S_pp_tuser;
wire         S_pp_tlast;
wire [127:0] S_pp_tdata;
wire [3:0]   S_pp_mode;
wire [4:0]   S_pp_sobel_sh;
wire [7:0]   S_pp_thresh;
wire         S_pp_morph_sel;
wire [7:0]   S_pp_morph_th;
wire [4:0]   S_pp_lap_sh;
wire [4:0]   S_pp_prew_sh;
wire [3:0]   S_pp_emboss_gain;
wire [7:0]   S_pp_emboss_bias;
wire [4:0]   S_basic_en;
wire         S_basic_gray;
wire [3:0]   S_basic_gauss;
wire [1:0]   S_basic_ker;
wire [7:0]   S_basic_he;
wire [7:0]   S_basic_he_clip;
wire         S_basic_linefix;
wire [3:0]   S_basic_contrast;

// 后级: 数字白平衡 + ROI 裁剪
wire         S_post_tvalid;
wire         S_post_tuser;
wire         S_post_tlast;
wire [127:0] S_post_tdata;
wire [7:0]   S_wb_r, S_wb_b;      // 白平衡增益, 128 = 1.0x
wire [6:0]   S_roi_pct;           // ROI 百分比
wire [2:0]   S_fps_div;           // 帧率分频 (跳帧)
// 单色标记: 高级层任一算子(都会输出 {0,gv,gv,gv}) 或初级-灰度 打开时，
// 图像已无颜色信息 —— 此时白平衡会把它染色，色度也应当强制为 128。
wire         S_mono_pp = (S_pp_mode != 4'd0) || S_basic_en[0];

rgb_to_yuv422_quad u_rgb2yuv_quad (
	.clk        (S_hs_rx_clk    ),
	.rst_n      (S_pll_lock     ),
	.i_de       (S_post_tvalid  ),   // 后级输出 (白平衡 + ROI)
	.i_user_sof (S_post_tuser   ),
	.i_last     (S_post_tlast   ),
	.i_data     (S_post_tdata   ),
	.i_mono     (S_mono_pp      ),
	.o_de       (S_yuv_de       ),
	.o_user_sof (S_yuv_sof      ),
	.o_last     (S_yuv_last     ),
	.o_data     (S_yuv_data     )
);


//=============================================================================
//  FPGA 硬件 JPEG 编码器接线 (2026-10-21)
//
//  ★ 默认**不**编译进设计 (`JPEG_EN 未定义), 因为还有两个硬约束没解决:
//
//  1) 吞吐/反压: 1080p60 的 S_yuv_data 是每拍一个 64bit word 的连续流,
//     而 jpeg_encoder_top 的有损路径约 312 clk/MCU -> 约 29fps, 而且节奏
//     不恒定 (DCT 固定 30 拍 + 熵编码变长)。直接串进这条流必然反压,
//     会冲垮已经调好的 CSI-2 定时 (GAP_LINE=200 是板上验证过的基线)。
//     要真正接进来, 必须先有帧缓冲 (DDR) 或把 DCT/熵编码改成 block 级并行。
//
//  2) 资源: 现有设计 DSP 已用 80%, 2D DCT 需要大量乘法器, 打开前必须先
//     综合一次看余量。
//
//  所以这里留一套**完整且能直接编译**的接线, 在文件头加
//      `define JPEG_EN 1
//  即可打开, 用来做资源评估或后续接入。
//
//  2026-10-21 实测基线 (不含 JPEG): slice 44624/64320 (69.4%),
//  ERAM 135/272 (49.6%), DSP 192/240 (80.0%) —— **DSP 只剩 48 个**,
//  而 2D DCT 的两级乘法树约需 64 个乘法器。也就是说打开后 DSP 会打满,
//  多出来的部分 TD 会用 LUT 实现 (每个约 300 LUT), slice 预计涨到 85% 左右。
//  这是能装下的, 但布线余量很小, 时序要盯紧。
//=============================================================================
`define JPEG_EN 1        // ← 打开硬件 JPEG 编码器 (要做资源评估就保持 1)

// ★ 这三根状态线必须在 ifdef **外**声明: cfg_ctrl_top 的例化在 ifdef 外,
//   而且它们的存在本身就是防止综合器把整个 JPEG 编码器优化掉的关键 ——
//   输出全悬空时 TD 会把 jpeg_encoder_top 整块删掉，资源数字和基线一模一样。
wire [23:0] S_jpeg_st_bytes;
wire        S_jpeg_st_busy;
wire        S_jpeg_st_done;

//=============================================================================
//  ★ 2026-10-29 V52b: 字节桥排水诊断 (复用已作废的 0xE4/0xE5)
//
//  板上 V52(0x5200) 实测把死锁钉到了这一段:
//    0xA5/A6 = 0x00/0x10 => encif_full=0x1(只有引擎0满), consume=0, mrg_segc=0
//    引擎0 = 0x1442 => T_HDR, lb_avail=1, m_ready=0
//    mrg_segc=0 说明 sel 从未前进, 于是 m_ready=0 只能是 o_ready_down=0,
//    也就是 jpeg_byte_bridge 的 w_ready=~f_full 为 0 —— **桥满**。
//
//  但"桥满"有两种完全不同的原因, 必须分开:
//    (a) 满 + 读侧不动  => 读侧死了 (r_ready 恒 0 / X_jv 不收 / 复位没放)
//    (b) 满 + 读侧在动  => 只是速率限住 (FWFT 握手 3 拍读 1 字节 = 41.7MB/s)
//    (c) 空 + 不动      => 问题在 merge4 没产出, 与桥无关
//
//  0xE4/0xE5 (16bit) = { 桥读侧剩余字节数 S_jb_lvl[7:0], 桥读侧已读字节计数 S_jb_rcnt[7:0] }
//    读两次间隔 1s:  rcnt 变 => 在排水;  rcnt 不变 => 读侧死了。lvl 看是否贴着 0xFF。
//  原占用者 D_lg1_s2 (cam1 每行组数) 是 NV16 时代的诊断, 已无用。
//  ⚠ 本声明必须在 ifdef 之外 (cfg_ctrl_top 例化在 ifdef 外)。
//=============================================================================
wire [15:0] S_diag_bridge;

//=============================================================================
//  ★ V53c (2026-10-29) 只读抽头 —— 复用 0xE6 / 0xE7 / 0xE9
//
//  目的: 分清「sel 卡在 1/2」和「桥的 f_full 假报满」——这两种都能导致
//        eng0 停在 T_HDR 且 m_ready=0, 现有寄存器区分不了。
//    0xE6 = { S_yuv_de, S_jcfg_valid, S_jcfg_consume, 4'b0, S_jpeg_m_ready }
//           bit0 = 桥 w_ready (1=可收)    => 0 就证明是 f_full 一直为 1
//           bit2 = S_jcfg_consume        => 源侧总反压
//           bit3 = S_jcfg_valid          => 源侧真的在给字
//           bit7 = S_yuv_de              => dbuf 读侧数据有效
//    0xE7 = 引擎1 o_diag[7:0]  (bit3:0 = tstate)
//    0xE9 = 引擎2 o_diag[7:0]  (bit3:0 = tstate)
//  原来占位的 D_tl_s2 / D_rxck_s2 / D_rtv_s2 是 2026-10-21 画面冻结排查用的,
//  现在 0xE1(sof) / 0xE3(vs) 已能证明源是活的, 所以可以腾出来。
//  ⚠ 声明必须在 ifdef 之外
//=============================================================================
wire [7:0]  S_diag_misc;
wire [7:0]  S_diag_e1;
wire [7:0]  S_diag_e2;


//=============================================================================
//  ★ 2026-10-28 V51: 移除 NV16 —— MIPI 输出只剩 JPEG 一条路
//
//  删除的东西 (全部是 NV16 专用):
//    - csi2_pack_yuv422_stream    YUV422 字节打包 + CDC
//    - csi2_frame_tx (定长)        每行一个定长长包 (DT=0x1E)
//    - csi2_test_src              内置测试图案 (它只能从定长 TX 出去)
//    - S_mark_* 读侧标记注入       往 NV16 的 Y 平面里塞 A5 5A, 对 JPEG 是污染
//    - TX_SRC_SEL / JPEG_TEST_SRC  三选一 mux
//
//  留下的唯一通路:
//    ui_dbuf.R -> yuv32_to_quad -> 4x jpeg_enc_if -> 4x jpeg_encoder_top
//      -> jpeg_seg_merge4 -> jpeg_byte_bridge -> csi2_frame_tx_var (变长)
//      -> mipi_dphy_tx_wrapper
//
//  寄存器语义随之固定:
//    0x0B[0] JPG_TX  锁死 1  (原来 0=NV16)
//    0x0B[1] DT18    锁死 0  (DT 必须是 0x1E, 见下)
//    0x0B[2] JPAD    保留为运行时开关, 默认 0 = 变长帧 (JPEG 本来的形态)
//
//  ⚠ 为什么 DT 仍然是 0x1E 而不是 JPEG 标准值 0x18:
//    这是**传输容器**, 不是数据格式。rkcif 完全没有 JPEG 支持
//    (CIF_FMT_TYPE 只有 YUV/RAW, capture.c 里自己写着 "JPEG, TODO"),
//    上报的 mbus code 只能是 MEDIA_BUS_FMT_YUYV8_2X8 => CSI-RX 按 DT=0x1E 收。
//    板上实测(0x470A): DT=0x18 直接被拒收, 报 MIPI_CSI2 err id + crc/ecc。
//    改成 0x1E 后 JPEG 字节就能当"普通像素"DMA 进帧缓冲, 应用层再扫
//    FF D8..FF D9 直接推流 —— 零解码零重编码 (见 docs/VARLEN_CSI2_JPEG_2026-10-28.md)。
//
//  为什么 3840 宽必须走 JPEG: NV16 3840x1080@60 需要 498MB/s, 而 4lane
//  1000Mbps 只有 500MB/s (99.6%), 且每行 2123 byte_clk @125MHz = 16.96us
//  超过 VTC 的 14.91us 行预算 13.7% -> 必然截包 -> CRC 满屏。
//=============================================================================
localparam      S_jpeg_tx_sel = 1'b1;
localparam      S_jpeg_dt18   = 1'b0;
localparam [5:0] S_jpeg_dt    = 6'h1E;
wire        S_jpeg_m_ready;
wire        S_jpeg_pad;         // 由 0x0B[2] 驱动, 默认 0 = 变长帧

// 2026-10-27: JPEG 支路诊断 (ifdef 内外都要声明, cfg 例化在外面)
//   0xA3~0xA6 = {看门狗触发次数, 源侧 FIFO 溢出次数}
//   0xA7      = 跨时钟桥 写侧背压低 8 位
wire [31:0] S_dbg_jpeg;
wire [7:0]  S_dbg_jb;

`ifdef JPEG_EN
	// V48: 原先这里的 S_jpeg_s_ready / S_jpeg_qt_a,b / S_jpeg_qta,qtb 单数声明已删
	//      —— 4 引擎改成 [0:3] 数组 (见下方 "四引擎各自的连线")。
	//      同名重复声明会让数组被后面的单数覆盖, 报 HDL-8007 cannot index non-array。
	wire        S_jpeg_m_valid, S_jpeg_m_last;
	wire [7:0]  S_jpeg_m_data;
	wire [31:0] S_jpeg_cnt;

	//==========================================================================
	//  2026-10-27: 编码器真正接入 (之前压根没接对)
	//  ------------------------------------------------------------------
	//  0x470A 实测: 0xA0~0xA2(帧字节数) 恒 0, 0xA8 bit0(busy) 恒 1
	//  => 编码器**从来没出过一帧**。原因就是当年注释里写的第 ③ 条:
	//  源是 64bit = 4 像素/拍, 只接了 s_data[31:0] = 2 像素, 每拍丢一半,
	//  行缓冲永远凑不满 8 行 => 停在 T_WGRP 等数据, busy 永远为 1。
	//  另外编码器原来挂在 S_hs_rx_clk(≈31MHz), 光时钟就只够 13fps。
	//
	//  现在: 源(S_hs_rx_clk, 4px/拍) -> jpeg_enc_if(异步FIFO+拆字)
	//        -> 编码器(S_pclkx1 147.5MHz, 2px/拍) -> jpeg_byte_bridge
	//        -> csi2_frame_tx_var(S_hs_rx_clk)
	//  实测 150 clk/MCU(有损) => 147.5MHz 下 128px/16.5us ≈ 60fps 上限。
	//
	//  ★ 必须整帧门控: 编码器是**连续流定长消费** (每帧恰好 (W/2)*H 个 word),
	//    一旦帧内丢一个 word 就永远等不到, 死锁。所以上一帧没编完时整帧丢掉,
	//    保证进去的每一帧都是完整的。
	//  ★ 还得有看门狗: FIFO 只有 1024 word(约 2 行), 极端情况下仍可能溢出,
	//    溢出后编码器必死锁。busy 超过 ~54ms 就复位编码器 + 清 FIFO 并重开闸。
	//==========================================================================
	// ★ 2026-10-27 实测(0x470B 时序报告): 编码器内部的 fmax 只有 **45.06MHz**
	//   (最差路径 X_jpeg_qt 异步读 -> u_quant 量化乘加 = 21.9ns,
	//    147.5MHz 下 WNS -15.413ns / 2591 个违例端点)。
	//   => 不能直接用 S_pclkx1。先用 S_hs_rx_clk(≈31.25MHz) 把功能跑通:
	//   31.25MHz 下 150 clk/MCU => 16200 MCU x 4.8us = 77.8ms/帧 ≈ 13fps。
	//   要上 30fps/60fps 必须先把量化/熵编码那一拍拆流水 (另开任务)。
	wire        S_enc_rst_n = S_pll_lock;

	// ★★ 帧门控状态：必须声明在【所有使用点之前】★★
	//   yuv32_to_quad 的 c_ready 和 S_jg_gcnt 都要用 S_enc_gate_r。
	//   如果声明在文件后部，Verilog 会先把它隐式声明成 1bit wire
	//   （TD 报 HDL-7225 "already implicitly declared"），功能静默出错。
	//   本工程已踩过多次，见 memory。
	wire        S_enc_flush;                 // 看门狗: 复位 FIFO + 编码器
	wire        S_enc_soft;
	reg         S_enc_done_tgl = 1'b0;       // 完成标志跑回 s_clk 用 (翻转同步)
	reg         S_enc_busy_f   = 1'b0;       // s_clk: 已放行一帧未完成
	reg         S_enc_gate_r   = 1'b0;

	// ★ 2026-10-28: 编码器时钟已改为独立的 pclkx1/4 = 36.875MHz (见时钟生成处)。
	//   原来的 45MHz fmax 卡点 (量化倒数表组合除法器) 已换成流水长除法，
        //   但要跑 146MHz 还差很远，所以这里不把它接到像素域 (=70.238MHz)。

	// ★ 2026-10-28: 双引擎 —— 左右各编 1920 宽的半行 (每组 120 MCU)。
	//   两个引擎都设 DRI=120, 于是每个半行是一个独立熵编码段,
	//   由 jpeg_seg_merge 交替拼成一张 3840x1080 的标准 JPEG。
	//   RST 编号用奇偶交错: 左 0,2,4.. 右 1,3,5.. -> 全局正好 0,1,2,...,7,0...
	//   ★ 左引擎 LAST_RST_EN=1: 它最后一段后面还跟着右引擎最后一段, 那个边界要标记。
	//==========================================================================
	// ★ 2026-10-28 V49: JPEG 直通源改为 dbuf 读侧 (DDR 三帧缓存)
        //   dbuf 读侧 32b=2px @147.5MHz -> yuv32_to_quad -> 64b=4px @70.238MHz
	//   283 Mpx/s 够 280 Mpx/s 需求, 且 FIFO 反压让 dbuf 停读 -> 数据留 DDR
	//==========================================================================
	wire        S_jcfg_valid;
	wire [63:0] S_jcfg_data;
	wire        S_jcfg_sof;
	wire        S_jcfg_last;
	wire        S_jcfg_r_ready;      // ★ 也要前置声明 (原声明在 dbuf 段, 会隐式声明成 1bit)

	// ★ V50a: 源侧反压只看"四个 enc_if 的 FIFO 装不装得下", 不再用帧门控。
	//   任何一个满了就停读 dbuf —— 数据留在 DDR 里, 这才是三帧缓存该起的作用。
	wire [3:0]  S_encif_full;

	// ★★ V54b (2026-10-30, 板上 0x5400 实测定案) ★★
	//   原来: S_jcfg_consume = ~(|S_encif_full)   <-- **四路取与**
	//   后果: 只要有一路 enc_if 满, 源就全停, 另外三路也饿死;
	//         而哪一路会满完全取决于 mux 当时选了谁 -> 单路憋死就能拖死全线。
	//   板上 0x5400 实测指纹 (与 V52 死锁时逐位相同):
	//     0xA3~A6( S_dbg_jpeg ) = ovf=1, mrg_segc=0, encif_full 只有一路=1
	//     0xA0~A2 = 0 (从没编完过一帧), 0xA7/0xE4/0xE5 = 0 (桥零字节)
	//     引擎0 = 0x1442 (T_HDR, m_ready=0)  引擎3 = 0x1167 (T_NEXT, pend=2)
	//   修法: 一拍数据只属于**一个**段(由 S_jg_gcnt 决定), 所以只需要
	//         "当前这一段对应的那一路" FIFO 能收就行, 其它三路满不满与这一拍无关。
	//   ⇒ 任何一路被 mux 卡住, 其它三路仍能正常吃数, 不会再被一起饿死。
	//   ⚠ S_jg_gcnt 必须先声明再用 (否则被隐式声明成 1bit wire, 本工程踩过多次)
	reg  [9:0]  S_jg_gcnt;
	wire [1:0]  S_jg_seg   = (S_jg_gcnt >= 10'd720) ? 2'd3 :
	                         (S_jg_gcnt >= 10'd480) ? 2'd2 :
	                         (S_jg_gcnt >= 10'd240) ? 2'd1 : 2'd0;
	wire        S_jcfg_consume = ~S_encif_full[S_jg_seg];

	yuv32_to_quad X_jcfg (
		.r_clk   (S_pclkx1          ),
		.r_rst_n (S_pll_lock        ),
		.r_valid (S_dsi_R_tvalid    ),
		.r_data  (S_ud_rtdata       ),
		.r_sof   (S_dsi_R_tuser     ),
		.r_last  (S_dsi_R_tlast     ),
		.r_ready (S_jcfg_r_ready    ),
		.c_clk   (S_hs_rx_clk       ),
		.c_rst_n (S_pll_lock        ),
		.c_valid (S_jcfg_valid      ),
		.c_data  (S_jcfg_data       ),
		.c_sof   (S_jcfg_sof        ),
		.c_last  (S_jcfg_last       ),
		.c_ready (S_jcfg_consume    )   // 只受 FIFO 满反压, 不受帧门控
	);

	// 读侧 group 计数 (每拍 4px, 一行 960 拍, 4 段各 240 拍)
	// ★ S_jg_gcnt 已在上面 V54b 块里前置声明 (供 S_jcfg_consume 使用)
	wire [3:0] S_jg_vld = { (S_jg_gcnt >= 10'd720),
	                        (S_jg_gcnt >= 10'd480) && (S_jg_gcnt < 10'd720),
	                        (S_jg_gcnt >= 10'd240) && (S_jg_gcnt < 10'd480),
	                        (S_jg_gcnt <  10'd240) };
	always @(posedge S_hs_rx_clk or negedge S_pll_lock) begin
		if (!S_pll_lock)   S_jg_gcnt <= 10'd0;
		// ★ 必须带 S_enc_gate_r: gate=0 时 c_valid 会一直挂着, 若只用 S_jcfg_valid
		//   计数, 分组边界会被冲飞 (仿真已验证此坑)。
		else if (S_jcfg_valid && S_jcfg_consume)
			S_jg_gcnt <= S_jcfg_last ? 10'd0 : (S_jg_gcnt + 10'd1);
	end

	reg [9:0] S_yuv_gcnt;
	// 2026-10-28 V48: 一行 960 group 切成 4 段, 每段 240 group = 960 像素 = 60 MCU
	//   group k 段: [0,240) [240,480) [480,720) [720,960)
	wire [3:0] S_eng_vld = { (S_yuv_gcnt >= 10'd720),
	                         (S_yuv_gcnt >= 10'd480) && (S_yuv_gcnt < 10'd720),
	                         (S_yuv_gcnt >= 10'd240) && (S_yuv_gcnt < 10'd480),
	                         (S_yuv_gcnt <  10'd240) };   // bit0 = 引擎0
	wire      S_yuv_left  = (S_yuv_gcnt < 10'd480);   // 保留旧名, 仅调试观察用
	always @(posedge S_hs_rx_clk or negedge S_pll_lock) begin
		if (!S_pll_lock)   S_yuv_gcnt <= 10'd0;
		else if (S_yuv_de) S_yuv_gcnt <= S_yuv_last ? 10'd0 : (S_yuv_gcnt + 10'd1);
	end

	// ---- 四引擎各自的连线 (2026-10-28 V48: 2 -> 4 引擎冲 60fps) ----
	//   每引擎 960 宽 => MCU_X = 960/16 = 60, MCU_Y = 135 => 8100 MCU/引擎
        //   4 引擎并行: 8100 x 151.3 clk = 1,225,530 clk
        //     @70.238MHz (C3=21) -> 17.45ms -> 57.31fps  < IMX415 的 60.0fps (会溢出)
        //     @73.75 MHz (C3=20) -> 16.617ms -> 60.19fps > 60.0fps  ✓  —— V54 采用这一档
        //   ⚠ clk3 域实测 fmax 约 73.9MHz, 73.75MHz 余量仅 ~0.2%.
        //     若综合后 WNS<0: 把 ui_pll.v 的 CLKC3_DIV 改回 21/CPHASE 20/DUTY 11,
        //     同时把 IMX415 的 VMAX(0x3024/25) 2283 -> 2400 (57.1fps) 与之匹配。
        //     详见 docs/V54_60FPS.md
		//   两路各 1920 宽再拆 2 段:  引擎0/1 吃 cam1(group 0..239/240..479)
		//                            引擎2/3 吃 cam0(group 480..719/720..959)
	wire        S_enc_v  [0:3];
	wire [31:0] S_enc_d  [0:3];
	wire [15:0] S_enc_ovf [0:3];
	wire [15:0] S_enc_words [0:3];
	wire        S_jpeg_s_ready [0:3];
	wire [6:0]  S_qt_a [0:3];
	wire [6:0]  S_qt_b [0:3];
	wire [7:0]  S_qta  [0:3];
	wire [7:0]  S_qtb  [0:3];
	wire [7:0]  S_jm_d [0:3];
	wire [15:0] S_diag_enc [0:3];
	wire [23:0] S_jpeg_bytes [0:3];
	wire [31:0] S_jpeg_fcnt  [0:3];
	// ★ 每路一个数组元素(由对应引擎驱动), 再拼成只读总线给合并器
	//   (不能直接对拼接 wire 的位赋驱动 -> multi-driver)
	wire        S_jm_v  [0:3];
	wire        S_jm_l  [0:3];
	// ★ V54c: S_jm_rdy[0:3] 已删除 —— 原来它被当作 mux o_ready 的驱动源(方向反了),
	//   现在编码器直接接 S_jm_rdy_p[gi_enc] (由 X_jmrg.o_ready 驱动)。
	wire        S_jseg  [0:3];
	wire        S_jpeg_busy [0:3];
	wire        S_jpeg_done [0:3];

	wire [3:0]  S_jm_v_p   = { S_jm_v[3],   S_jm_v[2],   S_jm_v[1],   S_jm_v[0]   };
	wire [3:0]  S_jm_l_p   = { S_jm_l[3],   S_jm_l[2],   S_jm_l[1],   S_jm_l[0]   };
	// ★★ V54c (2026-10-30) 修重大 bug: o_ready 是 merge4 的 **output**
	//   原来写的是
	//     wire [3:0] S_jm_rdy_p = { S_jm_rdy[3], S_jm_rdy[2], S_jm_rdy[1], S_jm_rdy[0] };
	//   把 merge4 的输出接到一条"由 S_jm_rdy 组合拼接出来"的 wire 上 ——
	//   **驱动方向完全反了**, 形成一个组合环。综合后 mux 的 o_ready 恒 0
	//   => 四个引擎的 m_ready 全为 0 => 引擎0 卡 T_HDR、引擎3 卡 T_NEXT
	//   => 一个字节都吐不出来 => 桥永远为空 (0xA7=0, 0xE4/E5=0, 0xEF 的 jb_v=0)。
	//   板上 0x5400 实测指纹 0x1442 / 0x1167 就是它。
	//   而台架 tb_wd 里是 .o_ready(e_rdy) 直接连 packed vector, 没有这段反向拼接,
	//   所以"台架 PASS、真机死锁"。
	//   ⇒ S_jm_rdy_p 改为由 X_jmrg 驱动, 再分位给 4 个引擎的 m_ready。
	wire [3:0]  S_jm_rdy_p;                      // 由 X_jmrg.o_ready 驱动
	wire [3:0]  S_jseg_p   = { S_jseg[3],   S_jseg[2],   S_jseg[1],   S_jseg[0]   };
	wire [3:0]  S_jpeg_busy_p = { S_jpeg_busy[3], S_jpeg_busy[2], S_jpeg_busy[1], S_jpeg_busy[0] };
	wire [3:0]  S_jpeg_done_p = { S_jpeg_done[3], S_jpeg_done[2], S_jpeg_done[1], S_jpeg_done[0] };
	wire [31:0] S_jm_d_pack = { S_jm_d[3], S_jm_d[2], S_jm_d[1], S_jm_d[0] };
	wire [9:0]  S_mrg_segc;
	reg         S_mrg_busy_d = 1'b0;
	reg         S_enc_soft_d = 1'b0;   // V51b: 软复位释放沿检测
	//==========================================================================
	//  ★★ 2026-10-28 V51b: 修段合并选择器的单向锁存 (板上硬冻结的根因)
	//
	//  板上现象 (0x5100, 6 次采样 3 秒内完全一致):
	//    引擎0 diag = 0x1442  -> tstate=T_HDR(2), lb_avail=1, bp_ok=1, m_ready=0
	//    引擎3 diag = 0x1167  -> tstate=T_NEXT(7), pend=2, huff_run=1, bp_ok=0
	//    两路 m_ready 都是 0 => sel 既不是 0 也不是 3 (卡在 1 或 2)
	//    S_enc_stall 每 ~114ms +1 (看门狗在响) 但状态纹丝不动
	//
	//  根因: jpeg_seg_merge4 的 sel 只在 i_start 时归零, 而
	//        i_start = (引擎0 busy 的上升沿)。
	//        看门狗软复位引擎0 后, 若 st_busy 没有产生下降沿, 就再也不会
	//        有上升沿 => sel 一卡住就永不归零:
	//          引擎0 在 T_HDR 等 hdr_done, 但没被选中 => m_ready=0
	//          => 帧头吐不出去 => 段永远完不成 => sel 永不前进 => 死锁。
	//
	//  修法: 看门狗软复位**释放那一拍**也强制 i_start, 让 sel 归零、done_p 清空,
	//        与引擎的复位同步重来。这样看门狗才真正起到"复位救活"的作用。
	//  ⚠ 必须在这两个 wire 被使用 (X_jmrg 例化) 之前声明, 否则会被 Verilog
	//    隐式声明成 1bit wire —— 这个坑本工程踩过多次。
	//==========================================================================
	wire        S_enc_rst_rel = S_enc_soft_d & ~S_enc_soft;   // 软复位释放拍
	//==========================================================================
	//  ★★ V53b (2026-10-29): **合并器 i_start 的根因修复** ★★
	//
	//  原来是: S_mrg_start = (S_jpeg_busy[0] & ~S_mrg_busy_d) | S_enc_rst_rel
	//          即拿"引擎0 st_busy 的上升沿"当帧起始。**这是错的**, 台架实测:
	//
	//    tb_wd 只改这一行, 其余完全相同 (70.238MHz + enc_if AW(12)/16行 + 桥4KB):
	//      m_start = 上电单拍 / 只由 rst_rel 触发 -> MERGED=6007 逐字节正确,
	//                                                segcnt=19, ENG by=1303/1394/1303/1392
	//      m_start = busy[0] 上升沿 (原接法)       -> MERGED=6620 (错), segcnt=0,
	//                                                **引擎1/2 输出 0 字节**
	//
	//  机理: jpeg_seg_merge4 的 i_start 会把 sel 清零 + done_p 清空。引擎0 的
	//  st_busy 并不是"帧开始"的可靠指示 —— 它在 i_soft_rst 里被清 0、帧尾 (line 775)
	//  也被清 0, 而且 i_en 恒 1 使得它随后立刻又置 1。于是这个"上升沿"会在帧中间
	//  反复出现, 每次都把 sel 拽回 0 并丢掉已经锁存的 done_p:
	//    -> 引擎1/2 永远轮不到 => 它们的 jpeg_bitpack 只有约 8 字节弹性, 憋死
	//    -> 它们的 enc_if 填满 => S_jcfg_consume = ~(|S_encif_full) 是**全局与**
	//    -> 一路满就饿死四路 => 源断流 => 谁也编不完 => 看门狗每 114ms 复位一次
	//    -> 但 i_flush 又把 enc_if 的 rd_go 清 0 (要重新攒够 16 行), 而全局反压
	//       让任何一路都攒不满 => **永久死锁, 看门狗永远救不活**
	//
	//  板上指纹 (0x5301 实测) 与此完全吻合:
	//    桥 lvl=0 rcnt=0 st_bp=0 (零字节), mrg_segc=0, encif_full 只有一路=1,
	//    consume=0, stall=746 且每 3s +25, eng0=0x1442(T_HDR,m_ready=0),
	//    eng3=0x1167(T_NEXT,pend=2,bp_ok=0) —— 与 V52 逐位相同。
	//
	//  修法: sel 不需要"每帧归零"。四引擎的段序本身就是 0,1,2,3 循环
	//        (RST_INIT=gi, RST_STEP=4), 只要在"编码器被复位"的那一拍归零即可
	//        —— 也就是 S_enc_rst_rel。上电时靠 rst_n 与 sel 的初值 2'd0。
	//==========================================================================
	wire        S_mrg_start   = S_enc_rst_rel;

	// (S_enc_flush / S_enc_soft / S_enc_done_tgl / S_enc_busy_f / S_enc_gate_r
	//  已前置声明在编码器时钟段之前, 勿重复声明)
	reg  [2:0]  S_enc_done_s   = 3'b000;
	wire        S_enc_done_pls = S_enc_done_s[2] ^ S_enc_done_s[1];
	reg  [23:0] S_enc_wd       = 24'd0;      // 卡死看门狗计数
	reg  [5:0]  S_enc_wdc      = 6'd0;       // 复位脉冲剩余拍数
	reg  [15:0] S_enc_stall    = 16'd0;      // 看门狗触发次数
	wire        S_jb_v, S_jb_l, S_jb_r;
	wire [7:0]  S_jb_d;
	wire [15:0] S_jb_bp;
    // ★ V53: jpeg_byte_bridge 的 AW 已从 9 改到 12, o_level 是 12 位 (0..4095);
    //   本诊断只取低 8 位拼 0xE4, 读回 0xFF 即当作"贴满"。
    wire [11:0] S_jb_lvl;
	//   位定义见 jpeg_encoder_top.v 的 o_diag 注释
	wire [7:0]  S_diag_enc_t;
	wire [7:0]  S_diag_jv;

	// ---- 帧门控 (保留仅供诊断, 已不参与数据通路) ----
	// ★ 2026-10-28 V50a: 板上实测 0xA0~A2=0 而 0xA3~A6(累计字节)=4031 且在涨,
	//   0xA8 s_ovf=0 (没丢数据), 0xEE 的 gate_r 在 0/1 之间跳。
	//   根因: 编码一帧 17.45ms > 帧周期 16.67ms, 所以一帧永远编不完 ->
	//   busy_f 恒 1 -> 下个 SOF 把 gate 关掉 -> 源断流 -> 引擎卡在半帧 -> 死锁。
	//   这正是搬到 DDR 读侧要解决的问题, 却又用一个帧门控接回去了。
	//   => JPEG 源通路彻底不用 gate, 只用 enc_if 的 FIFO 满反压。
	always @(posedge S_hs_rx_clk or negedge S_pll_lock) begin
		if (!S_pll_lock) begin
			S_enc_busy_f <= 1'b0;
			S_enc_gate_r <= 1'b0;
			S_enc_done_s <= 3'b000;
		end else begin
			S_enc_done_s <= {S_enc_done_s[1:0], S_enc_done_tgl};
			if (S_yuv_de && S_yuv_sof) begin
				S_enc_gate_r <= ~S_enc_busy_f;     // 仅作诊断观測
				if (!S_enc_busy_f) S_enc_busy_f <= 1'b1;
			end
			if (S_enc_done_pls) S_enc_busy_f <= 1'b0;
		end
	end

	// ---- 看门狗 (S_enc_clk 域) ----
	// ★ 改成按"引擎真的在前进"复位: 以 enc_if 的 st_word_lo 之和作为进度。
	//   原来的条件是 st_busy 持续 114ms —— 连续编码时 st_busy 永远为 1,
	//   那样看门狗会每 114ms 无条件 flush 一次, 把帧打碎。
	localparam [23:0] ENC_WD_MAX = 24'd8_000_000;
	wire [15:0] S_enc_prog = S_enc_words[0] + S_enc_words[1] + S_enc_words[2] + S_enc_words[3];
	reg  [15:0] S_enc_prog_d = 16'd0;
	always @(posedge S_enc_clk or negedge S_enc_rst_n) begin
		if (!S_enc_rst_n) begin
			S_enc_wd       <= 24'd0;
			S_enc_wdc      <= 6'd0;
			S_enc_stall    <= 16'd0;
			S_enc_done_tgl <= 1'b0;
			S_enc_prog_d   <= 16'd0;
		end else if (S_enc_wdc != 6'd0) begin
			S_enc_wdc <= S_enc_wdc - 6'd1;
			S_enc_wd  <= 24'd0;
		end else if (S_enc_prog != S_enc_prog_d) begin
			// 引擎在前进 -> 清计数
			S_enc_prog_d <= S_enc_prog;
			S_enc_wd     <= 24'd0;
		end else if (S_jpeg_st_done) begin
			S_enc_done_tgl <= ~S_enc_done_tgl;
			S_enc_wd       <= 24'd0;
		end else if (!S_jpeg_st_busy) begin
			S_enc_wd       <= 24'd0;
		end else if (S_enc_wd >= ENC_WD_MAX) begin
			S_enc_wdc      <= 6'd31;
			S_enc_wd       <= 24'd0;
			S_enc_stall    <= S_enc_stall + 16'd1;
			S_enc_done_tgl <= ~S_enc_done_tgl;
		end else begin
			S_enc_wd <= S_enc_wd + 24'd1;
		end
	end
	assign S_enc_flush = (S_enc_wdc != 6'd0);
	assign S_enc_soft  = (S_enc_wdc > 6'd16);

	//==========================================================================
	//  0xA3~0xA6 = 32 位, 拆成两半用:
	//    [15:0] = {S_enc_stall[15:0], 溢出标志}   —— 看门狗触发次数 (低 16 位)
	//    [31:16] = {S_encif_full[3:0], S_jcfg_consume, S_mrg_segc[9:0]}
	//
	//  V51b 为什么要看这两组:
	//    S_mrg_segc    = 段合并器已经切过的段数。它一直不动 => sel 卡死;
	//                    它在涨 => 合并其实在跑, 问题在别处。
	//    S_encif_full  = 四路 enc_if FIFO 的满标志。若读回 0xF,
	//                    说明"四路一起断流"这个全局与反压真的发生了 ——
	//                    此时任何一路卡住都会饿死其余三路, 这是设计级问题,
	//                    解法是给每路加独立输出 FIFO, 而不是调参数。
	//    S_jcfg_consume= 上面那个全局与本身。
	//==========================================================================
	assign S_dbg_jpeg = { S_encif_full, S_jcfg_consume, S_mrg_segc,
	                      S_enc_stall[15:0],
	                      (|(S_enc_ovf[0] | S_enc_ovf[1] | S_enc_ovf[2] | S_enc_ovf[3])) };
	assign S_dbg_jb   = S_jb_bp[7:0];
	// ★ V53c: 只读抽头 (0xE6/E7/E9)，见上方声明处的位定义
	assign S_diag_misc = { S_yuv_de, S_jcfg_valid, S_jcfg_consume, 4'b0000,
	                       S_jpeg_m_ready };
	assign S_diag_e1   = S_diag_enc[1][7:0];
	assign S_diag_e2   = S_diag_enc[2][7:0];
	// ★ 2026-10-28 诊断 (0xEE): 帧门控链状态
	//   [0] S_enc_gate_r  [1] S_enc_busy_f  [2] S_jpeg_st_busy  [3] S_jpeg_st_done
	//   [4] S_enc_flush   [5] S_enc_soft    [6] 看门狗复位中  [7] S_jpeg_tx_sel
	assign S_diag_enc_t = { S_jpeg_tx_sel, (S_enc_wdc != 6'd0), S_enc_soft,
	                        S_enc_flush, S_jpeg_st_done, S_jpeg_st_busy,
	                        S_enc_busy_f, S_enc_gate_r };
	//==========================================================================
	//  双引擎: 左引擎吃 group 0..479 (cam1), 右引擎吃 480..959 (cam0)
	//==========================================================================
	// 2026-10-28 V48: 4 引擎, 每引擎吃一行的 1/4 (240 word = 960 像素 = 60 MCU)
	//
	// ★★ V50 (仿真定调, 必须看) ★★
	//   jpeg_encoder_top **无法容忍 s_valid 断流**: 它的行缓冲一次要预取 8 行,
	//   若在预取途中断粮, 引擎会永久卡死 (吃 768/1024 后停), 而且熵编码器
	//   会持续吐垃圾 (~1 byte/clk, o_seg_done 永不置位)。
	//   仿真实测 (tb_eng_eif): 门限 6 行 FAIL / 7 行 PASS。
	//   每引擎每行 240 word, 所以缓冲需 ≥7*240=1680 -> FIFO 深度上到 2048,
	//   起送门限取 8 行 = 1920 word (留余量)。
	//   改完后 tb_jpeg_ddr4 与基准 merged4.jpg **逐字节完全相同 (6007 B)**。
	//
	//   s_valid 必须带 S_enc_gate_r: yuv32_to_quad 在 gate=0 时保持 c_valid 不变,
	//   不带的话同一个 word 会被重复写进 FIFO (仿真已复现)。
	//
	// ★★ V53 (完整链路仿真定案, 板上 0x5200 死锁根因) ★★
	//   V51/V52 用 AW(11)+START_LEVEL=1920 (8 行), 只考虑了"单引擎 1/4 源",
	//   没考虑 jpeg_seg_merge4 是 **4:1 串行 mux** —— 一个引擎的 seg 没结束,
	//   另外三路的 o_ready 恒 0, 而 jpeg_bitpack 只有约 8 字节输出弹性。
	//   于是: 桥满 -> mux 阻塞 -> 三路引擎 8 字节就憋死 -> 卡 T_NEXT(pend=2,bp_ok=0)
	//        -> enc_if 填满 -> 全局死锁 (板上 0xA5 显示 encif_full=0x1, mrg_segc=0)。
	//   完整链路仿真 tb_jpeg_full 复现完全一致:
	//     AW(9)  桥 + 8 行预取  -> TIMEOUT, 4 引擎 tstate=7/pend=2/bp_ok=0
	//     4KB 桥  + 8 行预取    -> 仍 TIMEOUT (桥 level=4094 贴满, 吐 142 KB 垃圾)
	//     4KB 桥  + 16 行预取   -> PASS, 6007 B 与基准逐字节相同, 且 H=64 也 PASS
	//   => 必须同时做两件事:
	//      ① jpeg_byte_bridge AW 9 -> 12 (4KB), 让 mux 下游永不阻塞
	//      ② 本处 AW 11 -> 12, START_LEVEL 1920 -> 3840 (16 行 x 240 word)
	//   ERAM 实测 201/272, 本改动约 +33 块, 余量仍够。
	genvar gi_encif;
	generate
	for (gi_encif = 0; gi_encif < 4; gi_encif = gi_encif + 1) begin : g_encif
		jpeg_enc_if #(.AW(12), .START_LEVEL(3840)) u_enc_if (
			.s_clk      (S_hs_rx_clk            ),
			.s_rst_n    (S_pll_lock             ),
			.s_valid    (S_jcfg_valid & S_jg_vld[gi_encif]),   // V50a: 不再带帧门控
			.s_data     (S_jcfg_data            ),
			.s_sof      (S_jcfg_sof             ),   // ★ 必须用读侧帧首, 不能用写侧 S_yuv_sof
			.e_clk      (S_enc_clk              ),
			.e_rst_n    (S_enc_rst_n            ),
			.i_flush    (S_enc_flush            ),
			.e_valid    (S_enc_v[gi_encif]       ),
			.e_data     (S_enc_d[gi_encif]       ),
			.e_ready    (S_jpeg_s_ready[gi_encif]),
			.st_ovf     (S_enc_ovf[gi_encif]     ),
			.st_word_lo (S_enc_words[gi_encif]   ),
			.st_sof     (                       ),
			.o_level    (                       ),
			.o_full     (S_encif_full[gi_encif] )
		);
	end
	endgenerate

	genvar gi_qt;
	generate
	for (gi_qt = 0; gi_qt < 4; gi_qt = gi_qt + 1) begin : g_qt
		jpeg_qtable_ram u_qt (
			.I_clk       (S_enc_clk       ),
			.I_rst_n     (S_enc_rst_n     ),
			.I_wr_en     (1'b0            ),
			.I_wr_addr   (8'd0            ),
			.I_wr_data   (8'd0            ),
			.I_rd_idx_a  (S_qt_a[gi_qt]   ),
			.O_rd_data_a (                ),
			.O_rd_data_a_asyn (S_qta[gi_qt]),
			.I_rd_idx_b  (S_qt_b[gi_qt]   ),
			.O_rd_data_b (S_qtb[gi_qt]    )
		);
	end
	endgenerate

	// ---- 4 引擎: 每引擎 960 宽 = 60 MCU/行, 共 60x135 = 8100 MCU ----
	//   引擎0: 出帧头(宽 3840) + 熵段, 不出 EOI; 引擎3: 不出帧头, 出 EOI
	//   RST 编号 0,1,2,3 交错 -> RST_INIT=gi, RST_STEP=4 (rst_idx 是 3bit, 自动回绕)
	//   每行 60 MCU 一个重启段 (i_rst_int=60)
	genvar gi_enc;
	generate
	for (gi_enc = 0; gi_enc < 4; gi_enc = gi_enc + 1) begin : g_enc
		jpeg_encoder_top #(.W(960), .H(1080),
		                   .HDR_EN(gi_enc == 0 ? 1 : 0),
		                   .EOI_EN(gi_enc == 3 ? 1 : 0),
		                   .RST_INIT(gi_enc),
		                   .RST_STEP(4),
		                   .LAST_RST_EN(gi_enc == 3 ? 0 : 1)) u_enc (
			.clk            (S_enc_clk            ),
			.rst_n          (S_enc_rst_n          ),
			.i_en           (1'b1                 ),
			.i_soft_rst     (S_enc_soft           ),
			.i_lossless     (1'b0                 ),
			.i_width        (12'd3840             ),   // 整幅宽, 而 W 参数是 960
			.i_height       (12'd1080             ),
			.i_rst_int      (16'd60               ),   // 1/4 行 = 60 MCU 一个重启段
			.o_qt_idx_a     (S_qt_a[gi_enc]       ),
			.i_qt_data_a    (S_qta[gi_enc]        ),
			.o_qt_idx_b     (S_qt_b[gi_enc]       ),
			.i_qt_data_b    (S_qtb[gi_enc]        ),
			.s_valid        (S_enc_v[gi_enc]      ),
			.s_data         (S_enc_d[gi_enc]      ),
			.s_ready        (S_jpeg_s_ready[gi_enc]),
			.m_valid        (S_jm_v[gi_enc]       ),
			.m_data         (S_jm_d[gi_enc]       ),
			.m_last         (S_jm_l[gi_enc]       ),
			.m_ready        (S_jm_rdy_p[gi_enc]),   // V54c: 直接用 mux 的输出
			.st_frame_bytes (S_jpeg_bytes[gi_enc] ),
			.st_busy        (S_jpeg_busy[gi_enc]  ),
			.st_done        (S_jpeg_done[gi_enc]  ),
			.st_frame_cnt   (S_jpeg_fcnt[gi_enc]  ),
			.o_seg_done     (S_jseg[gi_enc]       ),
			.o_diag         (S_diag_enc[gi_enc]   )
		);
	end
	endgenerate

	// ---- 段合并 (4:1): 引擎0 RST0, 1 RST1, 2 RST2, 3 RST3, 下一行再 0,1,2,3 ----
	jpeg_seg_merge4 X_jmrg (
		.clk          (S_enc_clk      ),
		.rst_n        (S_enc_rst_n    ),
		.i_start      (S_mrg_start    ),
		.i_valid      (S_jm_v_p       ),
		.i_data       (S_jm_d_pack    ),
		.i_last       (S_jm_l_p       ),
		.o_ready      (S_jm_rdy_p     ),
		.i_seg_done   (S_jseg_p       ),
		.o_valid      (S_jpeg_m_valid ),
		.o_data       (S_jpeg_m_data  ),
		.o_last       (S_jpeg_m_last  ),
		.o_ready_down (S_jpeg_m_ready ),
		.o_seg_cnt    (S_mrg_segc     )
	);

	// 合并器帧起始脉冲的延迟寄存器 (编码域)
	always @(posedge S_enc_clk or negedge S_enc_rst_n) begin
		if (!S_enc_rst_n) begin
			S_mrg_busy_d <= 1'b0;
			S_enc_soft_d <= 1'b0;
		end else begin
			S_mrg_busy_d <= S_jpeg_busy[0];
			S_enc_soft_d <= S_enc_soft;
		end
	end

	// ---- 两引擎的合成状态 ----
	//   ★ busy 用"或": 任一引擎没编完就不能开下一帧。
	//   ★ done 只在**两个都空闲**的那一拍脉冲一次, 否则上游会提前放行下一帧。
	assign S_jpeg_st_busy = |S_jpeg_busy_p;
	assign S_jpeg_st_done = (|S_jpeg_done_p) & ~(|S_jpeg_busy_p);
	assign S_jpeg_st_bytes = S_jpeg_bytes[0] + S_jpeg_bytes[1] + S_jpeg_bytes[2] + S_jpeg_bytes[3];
	assign S_jpeg_cnt      = S_jpeg_fcnt[0];

	//==========================================================================
	//  ★★ V52 (2026-10-29): 发送域时钟改回 S_dsi_byte_clk (与 D-PHY I_hs_clk 同源)
	//
	//  这是与「单目完美版 0x450D」交叉验证后发现的**唯一确凿回归**:
	//    0x450D: u_csi2_frame_tx.clk = S_dsi_byte_clk, D-PHY I_hs_clk 也是它 => 同域
	//    V51   : X_jv.clk = S_hs_rx_clk = 70.24MHz, D-PHY 仍是 125MHz
	//            => hs_en/hs_data[31:0]/hs_last **32 位裸跨 70->125, 无任何同步**
	//            125/70.24 = 1.78 非整数比 => 每个 70MHz 数据拍被 125MHz 采 1 或 2 次
	//            => 随机重复/丢字节, 码流不可能正确。
	//
	//  改法: 把整条「字节桥读侧 + S_jl_* 补零/丢弃状态机 + var 组包」搬到
	//        S_dsi_byte_clk。jpeg_byte_bridge 内部就是异步 FIFO(fifo_32b_async_2),
	//        所以 70.24MHz 写 / 125MHz 读天然成立, 且它成为**唯一**的 CDC 点。
	//        这样就和 0x450D 的干净度一致: 组包器与 D-PHY 之间零跨域。
	//==========================================================================
	// 发送域复位: 两路 PLL 都锁定才放开 (不加 S_dsi_en_int, 否则 RK 停流会打断包)
	wire S_tx_domain_rst_n = S_pll_lock & S_dsi_pll_lock;

	// 编码器字节流 (70.24MHz) -> 发送域 (S_dsi_byte_clk 125MHz, 异步 FIFO)
	// ★★ V53: 深度 512B -> 4096B (AW 9 -> 12)。
	//   原因: jpeg_seg_merge4 的 4:1 mux 一次只能服务一路, 而 jpeg_bitpack 只有
	//   约 5 字节输出弹性。桥一满 -> o_ready_down=0 -> 三路非选中引擎 5 字节就憋死
	//   -> 卡在 T_NEXT(pend=2, bp_ok=0) -> enc_if 填满 -> 全局死锁。
	//   板上 0x5200 与 iverilog 全链仿真 tb_jpeg_full 完全一致。
	//   代价: 4096 x 9bit = 36 kbit ≈ 2 个 ERAM 块。
	jpeg_byte_bridge #(.AW(12)) X_jb (
		.w_clk   (S_enc_clk        ),
		.w_rst_n (S_enc_rst_n      ),
		.w_valid (S_jpeg_m_valid   ),
		.w_data  (S_jpeg_m_data    ),
		.w_last  (S_jpeg_m_last    ),
		.w_ready (S_jpeg_m_ready   ),
		.r_clk   (S_dsi_byte_clk   ),
		.r_rst_n (S_tx_domain_rst_n),
		.r_valid (S_jb_v         ),
		.r_data  (S_jb_d         ),
		.r_last  (S_jb_l         ),
		.r_ready (S_jb_r         ),
		.st_bp   (S_jb_bp         ),
		.o_level (S_jb_lvl        )
	);

	// CSI-2 可变长发送 (乒乓双缓冲): 编码器输出是连续字节流,
	// 也不知道每包多大, 所以走 csi2_frame_tx_var。乒乓让攒包和发包并行,
	// s_tready 基本一直为 1, 避免编码器的 block 流水被长停顿打乱。
	wire        S_jv_hs_en, S_jv_hs_last;
	wire [31:0] S_jv_hs_data;

	//==========================================================================
	//  2026-10-27  JPEG 帧尾补零 / 截断 (0x0B[2])
	//  ---- 为什么需要 ----
	//  rkcif 的 DMA 按媒体格式 w*h*bpp 往 DDR 写: 1920x1080 NV16 = 4147200
	//  字节/帧。JPEG 一帧只有 ~120KB, 短帧会不会被当成完整帧由收端决定,
	//  没验证前先用"补满整帧"这个与现有 NV16 通路完全一致的行为。
	//  ---- 另一个作用 ----
	//  编码器异常时帧字节数可能超过整帧 (0x4708 出现过 4694772 > 4147200),
	//  这里超限即截断并吞掉本帧剩余字节, 顺便保护链路不被灌爆。
	//  ---- 输出是组合的 ----
	//  必须跟着 S_jv_r (var TX 的 s_tready) 走组合, 不能打拍 ——
	//  打拍就成了"不看背压丢字节", JPEG 会花屏。
	//==========================================================================
	localparam [24:0] JPAD_BYTES = 25'd8_294_400;   // 3840*1080*2 (拼接后整幅 NV16)
	localparam [1:0]  JLS_DATA = 2'd0;   // 转发编码器字节
	localparam [1:0]  JLS_PAD  = 2'd1;   // 补零
	localparam [1:0]  JLS_DROP = 2'd2;   // 本帧已超限, 吞掉剩余字节

	reg  [1:0]  S_jl_st  = JLS_DATA;
	reg  [24:0] S_jl_cnt = 25'd0;
	// S_jv_rx_ready 由 X_jv 的 s_tready **输出**驱动, 不要在本文件里再 assign 它
	wire        S_jv_rx_ready;

	wire        S_jv_v = (S_jl_st == JLS_PAD ) ? 1'b1 :
	                     (S_jl_st == JLS_DATA) ? S_jb_v : 1'b0;
	wire [7:0]  S_jv_d = (S_jl_st == JLS_PAD ) ? 8'h00 : S_jb_d;
	// tlast: 补零阶段 = 补到最后一个字节; 数据阶段 = 编码器帧尾(pad 关时)
	//        或本帧已满被截断
	wire        S_jv_l = (S_jl_st == JLS_PAD ) ? (S_jl_cnt == JPAD_BYTES - 25'd1) :
	                     (S_jl_st == JLS_DATA) && S_jb_v &&
	                       ( (S_jb_l && !S_jpeg_pad) ||
	                         (S_jl_cnt >= JPAD_BYTES - 25'd2) );

	// 编器字节流来自字节桥读侧 (V52 起是 S_dsi_byte_clk 域, 与 var 组包同域)
	// ★ 2026-10-28 二次修复: DATA 转发 / DROP 抽走丢弃 / PAD 期间必须停
	//   (PAD 是插补零, 排桥会把编码器下帧的字节混进补零段)
	assign S_jb_r = (S_jl_st != JLS_PAD) ? S_jv_rx_ready : 1'b0;

	// ★ V52b: 桥读侧"已经读出去多少个字节"。它不动就证明桥的读侧彻底死了。
	//   握手条件与 jpeg_byte_bridge 内部一致: h_v && r_ready 才算真的送出一个字节。
	reg [7:0] S_jb_rcnt;
	always @(posedge S_dsi_byte_clk or negedge S_tx_domain_rst_n) begin
		if (!S_tx_domain_rst_n) S_jb_rcnt <= 8'd0;
		else if (S_jb_v && S_jb_r) S_jb_rcnt <= S_jb_rcnt + 8'd1;
	end
	// 0xE4/0xE5 = { 桥读侧剩余字节数低8位, 已读出字节计数 }
	//   满水位实际是 511; 这里取低 8 位, 读回 0xFF 就当作"贴满"。
	assign S_diag_bridge = { S_jb_lvl[7:0], S_jb_rcnt };

	// ★ 2026-10-28 诊断 (0xEF): JPEG 字节排水链状态
	//   [1:0] S_jl_st (0=DATA 1=PAD 2=DROP)  [2] V52b: S_dsi_pll_lock
	//   [3] S_jpeg_pad
	//   [4] S_jb_r (桥读完成)  [5] S_jv_rx_ready (发送器收)  [6] S_jb_v  [7] S_jb_l
	//   [2] 原来是"S_jl_cnt 是否超过 4M字节", 那个用 0xE4 的 lvl 就能看出来;
	//   改成 dsi_pll_lock 是因为 S_tx_domain_rst_n 含它 —— 它若为 0, 桥读侧被
	//   按在复位里永不出数, 表现与"读侧死了"完全一致, 必须先排除。
	assign S_diag_jv = { S_jb_l, S_jb_v, S_jv_rx_ready, S_jb_r,
	                     S_jpeg_pad, S_dsi_pll_lock, S_jl_st };

	// ★★ 2026-10-28 二次死锁修复 (0x4712)
	//   原实现把整条 case 包在 `else if (S_jv_v && S_jv_rx_ready)` 里, 而 JLS_DROP
	//   状态本身就让 S_jv_v=0 —— 于是 DROP 的退出条件 (S_jb_v && S_jb_l)
	//   **永远不可能被求值**。一进 DROP 就是永久死锁 (板上实测 S_jl_st 恒 = DROP)。
	//   改成:
	//     1) DROP 单独在发送门之外处理;
	//     2) DROP 期间照样把桥里的字节抽走丢弃 (S_jb_r 在 DROP 也为 1),
	//        否则桥会写满 -> 合并器 o_ready=0 -> 两个编码器又被反压卡死;
	//     3) 加 4096 拍超时兜底, 帧尾永远不来也不能死锁。
	reg [11:0] S_jl_to = 12'd0;

	// ★ V52: 时钟从 S_hs_rx_clk 改为 S_dsi_byte_clk —— 必须与 X_jv 及字节桥读侧同域
	always @(posedge S_dsi_byte_clk or negedge S_tx_domain_rst_n) begin
		if (!S_tx_domain_rst_n) begin
			S_jl_st  <= JLS_DATA;
			S_jl_cnt <= 25'd0;
			S_jl_to  <= 12'd0;
		end else if (S_jl_st == JLS_DROP) begin
			// ---- 丢弃阶段: 不发送, 但必须把桥抽空; 帧尾来了或超时就恢复 ----
			if (S_jb_v && S_jb_l) begin
				S_jl_st  <= S_jpeg_pad ? JLS_PAD : JLS_DATA;
				S_jl_cnt <= 25'd0;
				S_jl_to  <= 12'd0;
			end else if (S_jl_to == 12'hFFF) begin
				S_jl_st  <= JLS_DATA;          // 强制恢复, 不允许再死锁
				S_jl_cnt <= 25'd0;
				S_jl_to  <= 12'd0;
			end else begin
				S_jl_to <= S_jl_to + 12'd1;
			end
		end else if (S_jv_v && S_jv_rx_ready) begin
			S_jl_to <= 12'd0;
			case (S_jl_st)
			JLS_DATA: begin
				if (S_jb_l && S_jpeg_pad) begin
					S_jl_st  <= JLS_PAD;            // 转补零
					S_jl_cnt <= S_jl_cnt + 25'd1;   // 本拍已发 1 字节
				end else if (S_jb_l) begin
					S_jl_cnt <= 25'd0;              // 短帧直通, 帧结束
				end else if (S_jl_cnt >= JPAD_BYTES - 25'd2) begin
					S_jl_st  <= JLS_DROP;           // 满帧截断
					S_jl_cnt <= 25'd0;
				end else begin
					S_jl_cnt <= S_jl_cnt + 25'd1;
				end
			end
			JLS_PAD: begin
				if (S_jl_cnt >= JPAD_BYTES - 25'd1) begin
					S_jl_st  <= JLS_DATA;           // 补满, 等下一帧
					S_jl_cnt <= 25'd0;
				end else begin
					S_jl_cnt <= S_jl_cnt + 25'd1;
				end
			end
			default: begin                          // JLS_DROP
				// 不可达: DROP 已在 case 外单独处理
				S_jl_st  <= JLS_DATA;
				S_jl_cnt <= 25'd0;
			end
			endcase
		end
	end

	csi2_frame_tx_var #(
		.PKT_BYTES (1024),
		.GAP_FRAME (200 ),
		.VC        (2'b00)
	) X_jv (
		// ★★ V52: 与 D-PHY 的 I_hs_clk 同一根时钟, 消除 32 位裸跨域
		.clk        (S_dsi_byte_clk   ),
		.rst_n      (S_tx_domain_rst_n),
		// ★ V51: 原来接 0x0B[0] (NV16 时要置 0 才关掉 JPEG)。现在 NV16 没了,
		//   改接 RK 的 stream-on 信号 —— enable=0 会清空乒乓缓冲, 所以不能让
		//   D-PHY 还在复位时就把整包塞进去, 否则 RK 开流后第一帧是残帧。
		.enable     (S_dsi_en_int   ),
		.i_dt       (S_jpeg_dt      ),
		.s_tvalid   (S_jv_v         ),
		.s_tdata    (S_jv_d         ),
		.s_tlast    (S_jv_l         ),
		.s_tready   (S_jv_rx_ready  ),
		.hs_en      (S_jv_hs_en     ),
		.hs_data    (S_jv_hs_data   ),
		.hs_last    (S_jv_hs_last   ),
		.frame_cnt  (               ),
		.packet_cnt (               ),
		.byte_cnt   (               )
	);
`endif

`ifndef JPEG_EN
	// 未启用时给 cfg 只读寄存器一个确定值 (否则读到 X)
	assign S_dbg_jpeg = 32'd0;
	assign S_dbg_jb   = 8'd0;
	assign S_diag_bridge = 16'd0;   // V52b
	assign S_diag_misc   = 8'd0;    // V53c
	assign S_diag_e1     = 8'd0;    // V53c
	assign S_diag_e2     = 8'd0;    // V53c
	assign S_jpeg_st_bytes = 24'd0;
	assign S_jpeg_st_busy  = 1'b0;
	assign S_jpeg_st_done  = 1'b0;
	wire        S_jv_hs_en   = 1'b0;
	wire        S_jv_hs_last = 1'b0;
	wire [31:0] S_jv_hs_data = 32'd0;
	assign S_jpeg_m_ready    = 1'b0;
`endif


//PLL时钟管理IP 
ui_pll X_ui_pll (
    .refclk  	(I_sysclk_25m	),
    .reset		(1'b0			),

    .lock		(S_pll_lock		),

    .clk0_out	(S_clk_24m		),
    .clk1_out	(S_pclkx1		),
    .clk2_out	(S_pclkx5		),
    .clk3_out	(S_clk_70m		)
  );

PH1_LOGIC_ODDR X_cam_clk (
    .q  		(O_clk_24m	), 
    .clk		(S_clk_24m	),
    .d0 		(1'b1		),
    .d1 		(1'b0		),
    .rst		(1'b0		)
  );

// cam1 的 24MHz 主时钟 (J13 = LA28_P = 子卡 DSI_CLK, 经 R91 22R 到 J3 pin8)
//   和 cam0 一样用 ODDR 从 24MHz 时钟产生, 占空比 50%、相位与 cam0 同源。
//   两路同时输出没任何副作用: 没接摄像头的那一路就是空跑。
PH1_LOGIC_ODDR X_cam1_clk (
    .q  		(O_clk_24m_1), 
    .clk		(S_clk_24m	),
    .d0 		(1'b1		),
    .d1 		(1'b0		),
    .rst		(1'b0		)
  );

//=============================================================================
//  摄像头参数下发 (曝光 / 增益 / 曝光补偿)
//
//  原来这一步由厂商的 ui_ae_set 驱动, 它内部的 ae_reg 直接跟随 VPI_0 的
//  outprobe0 探针输出 (见 ui_ae_set.v 结尾的例化)。VPI 的初值虽然在工程里
//  是 0x50, 但那是 JTAG 写进去的运行时值, 不在 bit 流里 —— 不接 JTAG 时
//  增益会变成 0dB, 画面直接黑掉。
//  现在改由 cam_param 从寄存器堆 (I2C 0x40) 取参数, 完全可控,
//  而且网页可以实时调。ui_ae_set 不再例化。
//=============================================================================
//=============================================================================
//  V24 (2026-10-16): 传感器读出模式 + 全表重载请求
//
//  ⚠ 这两个信号在文件**更早**的位置 (ui_cfg_imx415 例化) 就要用到, 所以声明
//     必须放在这里 —— 否则会被 Verilog 隐式声明成 1bit wire, 而 ui_cfg 那边
//     期望 2bit 的 mode, 编译只会报一条 HDL-7225 位宽警告, 到板上才发现模式
//     根本没传过去。(和之前 S_pp_* 下移踩过的坑一模一样。)
//     真正的产生逻辑在下面 "V24: 分辨率切换时还要做两件事" 那一节。
//=============================================================================
wire [1:0] S_cam_mode_24;
wire       S_full_reload;

// ---- 传感器读出模式 -> 24MHz 域 (ui_cfg_imx415 挂在 S_clk_24m) ----
//   RES_MODE: 0=1080p60, 1=4K30, 2=4K25; 传感器的 MODE 只要 0=1080p / 1=4K
wire [1:0] S_sensor_mode = S_is_4k ? 2'd1 : 2'd0;
// V39: 真正的 2 级同步。原来的 {r[0], S_sensor_mode} 是 3bit 赋给 2bit，
//      最高位被截断，实际只有 1 级寄存 (4K 时输出 1 纯属巧合)。
//      这里只同步最低位 (MODE 只有 0/1)，输出固定高位为 0。
reg  [1:0] S_cam_mode_24_r;
always @(posedge S_clk_24m or negedge S_pll_lock) begin
	if (!S_pll_lock) S_cam_mode_24_r <= 2'd0;
	else             S_cam_mode_24_r <= {S_cam_mode_24_r[0], S_sensor_mode[0]};
end
assign S_cam_mode_24 = {1'b0, S_cam_mode_24_r[1]};

wire [19:0] S_cam_exp;
wire [7:0]  S_cam_gain;
wire [3:0]  S_cam_ev;
wire [7:0]  S_cam_trig;
wire [15:0] S_cam_wr_cnt;
wire        S_cam_busy;
wire        S_ae_req_pulse;     // cam_param 输出 (25MHz 域, 单拍)
wire [7:0]  S_ae_gain;
wire [19:0] S_rt_exp;
wire        S_ae_cfg_done_25;   // 24MHz 域同步回来的“本轮写完”

cam_param u_cam_param (
	.clk        (I_sysclk_25m),
	.rst_n      (S_pll_lock),
	// V38e: 4K 传感器帧率配到 25.0fps 以匹配 VTC。
	//   实测: VMAX=3449 -> 24.83fps, 反推行时间 = 1/(24.83x3449) = 11.679us
	//   25.0fps 需要帧长 40.0ms => VMAX = 40.0ms/11.679us = 3425
	//   取 3420 => 25.04fps (比 VTC 的 24.997 略快, 让读侧等写侧而不是读空)
	//
	//   ★★★ 这个 i_vmax 和 ui_imx415_reg.v 的 0x3024/0x3025 **必须同时改** ★★★
	//   i_vmax 只用于算曝光(SHR0), 真正决定帧长的是传感器寄存器 0x3024/25。
	//   V38c 我就只改了 i_vmax 忘了改寄存器, 结果传感器还是 24.83fps, 白烧一次。
	//   当前两边都是 3420 = 0x0D5C (0x3024=0x5C, 0x3025=0x0D)
	.i_vmax         (S_is_4k ? 20'd3420        : 20'd2283),
	.i_gain_default (S_is_4k ? 8'h10 : 8'h20   ),
	// V39: 4K 默认曝光从「满帧 39.85ms」降到 15ms (3420-1284=2136)；
	//      1080p 保持原来的 SHR0=8。注意 i_shr0_default 必须与
	//      ui_imx415_reg.v 的 0x3050/51 初值一致。
	.i_shr0_default (S_is_4k ? 20'd2136 : 20'd8),
	.i_exp      (S_cam_exp),
	.i_gain     (S_cam_gain),
	.i_ev_bias  (S_cam_ev),
	.i_trig     (S_cam_trig),
	.o_ae_req   (S_ae_req_pulse),
	.o_ae_gain  (S_ae_gain),
	.o_rt_exp   (S_rt_exp),
	.i_ae_done  (S_ae_cfg_done_25),
	.o_wr_cnt   (S_cam_wr_cnt),
	.o_busy     (S_cam_busy)
);

//---- 跨域: 25MHz -> 24MHz (ui_cfg_imx415 挂在 S_clk_24m) ----
// req 是单拍脉冲, 而两个时钟只差 4%, 直接跨域很可能被整拍漏掉。
// 所以先展宽成电平, 再两级同步, 最后在 24MHz 域取上升沿变回单拍。
// (ui_cfg_imx415 的 I_ae_req 是电平敏感的: 保持高会反复清零 reg_index,
//  永远写不完, 所以到那边必须是单拍。)
reg [3:0] S_ae_stretch;
reg [2:0] S_ae_sync_24;
reg [19:0] S_exp_24_s1, S_exp_24_s2;
reg [7:0]  S_gain_24_s1, S_gain_24_s2;

wire S_ae_req_lvl = (S_ae_stretch != 4'd0);
wire S_ae_req_24  = (S_ae_sync_24[2:1] == 2'b01);   // 24MHz 域的单拍脉冲

always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) S_ae_stretch <= 4'd0;
	else if (S_ae_req_pulse) S_ae_stretch <= 4'hF;
	else if (S_ae_stretch != 4'd0) S_ae_stretch <= S_ae_stretch - 4'd1;
end

always @(posedge S_clk_24m or negedge S_pll_lock) begin
	if (!S_pll_lock) begin
		S_ae_sync_24   <= 3'b000;
		S_exp_24_s1    <= 20'd0; S_exp_24_s2    <= 20'd0;
		S_gain_24_s1   <= 8'd0;  S_gain_24_s2   <= 8'd0;
	end else begin
		S_ae_sync_24   <= {S_ae_sync_24[1:0], S_ae_req_lvl};
		// 数据在 req 之前几十个周期就稳定了, 两级同步足够
		S_exp_24_s1    <= S_rt_exp;      S_exp_24_s2    <= S_exp_24_s1;
		S_gain_24_s1   <= S_ae_gain;     S_gain_24_s2   <= S_gain_24_s1;
	end
end

//---- 回: 24MHz 的“写完了”同步到 25MHz ----
reg [2:0] S_ae_done_sync;
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) S_ae_done_sync <= 3'b000;
	else S_ae_done_sync <= {S_ae_done_sync[1:0], S_ae_cfg_done};
end
assign S_ae_cfg_done_25 = S_ae_done_sync[2];

//IIC协议配置摄像头寄存器
ui_cfg_imx415#(
	.CLK_DIV(24_000_000/100_000-1)
	)
X_ui_cfg_imx415(
	.I_clk			(S_clk_24m		),  
	.I_rst_n		(S_pll_lock & ~S_cfg_hold	),  
	// V24: 传感器读出模式 + 整表重载
	.I_ae_req		(S_ae_req_24	),
	.I_cam_mode		(S_cam_mode_24	),
	.I_full_reload	(S_full_reload	),
	.I_ae_data		(S_gain_24_s2	),
	.I_rt_exp		(S_exp_24_s2	),
	.O_cam_scl		(O_cam_scl		), 
	.IO_cam_sda		(IO_cam_sda		), 
	.O_cfg_done		(S_cam_cfg_done	),
	.O_ae_cfg_done	(S_ae_cfg_done	)
  );

//=============================================================================
//  cam1 (子卡 J3 / 原 DSI 座) 的 SCCB 配置 —— 第二个 ui_cfg_imx415
//
//  为什么直接做成两个实例，而不是"一个主控 + 引脚二选一"：
//    1) ui_i2c 的 SDA 是 open-drain inout，做双向开关必须把 oe 引出来，
//       那要同时改 ui_i2c 和 ui_cfg_imx415 的端口，反而更容易碰坏 cam0 现成能跑的路径；
//    2) 两个实例**同时**跑，上电就把两颗都配好 —— 正好满足"每一路都能单独测试"，
//       换源时不需要再等一遍初始化表（201 个寄存器 ≈ 99ms）。
//  资源代价：用例 0x450D 的 LUT 是 17048（余量很大），复制一张表完全吃得下。
//
//  ⚠ 两颗都写在同一个 S_clk_24m 域，同一个 I_ae_req / I_full_reload 脉冲，
//    所以曝光/增益/分辨率切换对两路是同步生效的。
//  ⚠ O_cfg_done / O_ae_cfg_done 只取第 0 路（cam_param 的握手用它）。
//    没接 cam1 时，第 1 路会因为收不到 ACK 而在内部绕圈重试，但不影响第 0 路。
//=============================================================================
ui_cfg_imx415#(
	.CLK_DIV(24_000_000/100_000-1)
	)
X_ui_cfg_imx415_1(
	.I_clk			(S_clk_24m		),  
	.I_rst_n		(S_pll_lock & ~S_cfg_hold	),  
	.I_ae_req		(S_ae_req_24	),
	.I_cam_mode		(S_cam_mode_24	),
	.I_full_reload	(S_full_reload	),
	.I_ae_data		(S_gain_24_s2	),
	.I_rt_exp		(S_exp_24_s2	),
	.O_cam_scl		(O_cam_scl_1	), 
	.IO_cam_sda		(IO_cam_sda_1	), 
	.O_cfg_done		(),
	.O_ae_cfg_done	()
  );

//=============================================================================
//  V23 (2026-10-16): 分辨率模式切换 —— **整条视频通路**协同复位
//
//  V21/V22 只复位了读侧 (ui_vtc / csi2_pack / csi2_frame_tx), 窗口 0.44ms。
//  实测结果: 不再硬死锁了, 但画面撕裂 —— 右/下会出现一份错位的重复图像,
//  而且重启采集后码流会彻底断掉。原因两处, 一起修掉:
//
//   (a) **窗口太短**: 0.44ms 连一帧的零头都不到 (1080p60 一帧 16.7ms,
//       4K25 一帧 40ms)。写侧一整帧的数据还在流水线里飞, 复位就结束了,
//       于是旧模式的残帧和新模式的帧混在一起 => 就是那个错位的重复图像。
//       这里改成 80ms (> 2 帧 4K25), 保证窗口内没有任何跨模式残帧。
//
//   (b) **写侧完全没复位**: ui_image_correction / ui_isp_top / preproc_*
//       内部的行/组计数器和裁剪边界都跟 S_h_active / S_v_active 走(它们会
//       随模式变), 不复位的话它们会一直按旧边界切, 写进 DDR 的帧本身就是
//       错位的 —— 读侧再怎么对齐也救不回来。这里把复位窗同步到
//       S_hs_rx_clk 域, 把整条写侧也一起复位。
//
//  实现说明:
//   - 窗在 **25MHz 域**生成(S_res_chg 本来就是那一拍的 25MHz 脉冲),
//     再各自 2 级同步到三个域。窗长 80ms, 跨域完全不用担心亚稳态展宽。
//   - **不要**去复位 D-PHY RX wrapper: S_hs_rx_clk 就是它恢复出来的,
//     复位它会让上面这些同步器直接失去时钟。
//   - 本块必须放在**所有使用点之前**(Verilog 先声明后使用)。之前 S_pp_*
//     下移踩过这个坑(被隐式声明成 1bit), 勿再移动。
//=============================================================================
// 500 ms @ 25MHz。为什么要这么长: 切模式不只受复位窗控制, 还要等
//   ui_cfg_imx415 把传感器**整张初始化表重写一遍**, 再加上传感器重新锁相、
//   D-PHY RX 重新锁定(要等下面的 250ms 释放)、写侧重新攒够几帧。
//   时序账: 全表重写 201x385us ≈ 78ms (+ 绕圈的垃圾写, 共 ~257 次 ≈ 99ms)
//           D-PHY RX 复位保持 250ms 才释放
//           => 视频通路窗口必须 > 250ms, 否则 RX 还没锁上窗口就结束了。
localparam [23:0] RES_RST_CYCLES = 24'd12_500_000;  // 500 ms @ 25MHz
// 2026-10-21 双路: **换 CSI 源** 的写侧复位窗。
//   比切分/4K 短很多 —— 不需要重写传感器表、也不需要重锁 RX，
//   只要让 ui_image_correction / ISP / 预处理的行列计数器重新对齐新源。
//   1080p 一帧 16.7ms，120ms ≈ 7 帧，足够把旧源的残帧冲干净。
localparam [23:0] SRC_RST_CYCLES = 24'd3_000_000;   // 120 ms @ 25MHz
// 写侧(含 ISP/预处理)一起复位。若万一某版 ISP 的复位恢复时间不可接受,
// 把这一个常量置 0 即可退回"只复位读侧"的旧行为, 不用改别的地方。
localparam        RES_RST_TX_SIDE = 1'b1;

//--------------------------------------------------------------------------
//  2026-10-21: "换源"检测 + D-PHY RX 复位脉冲
//
//  ⚠ 为什么必须复位 RX IP（不只是下游的 ui_image_correction）:
//    m_axis_video_aclk 接的是 S_hs_rx_clk，而它就是 mux 在
//    S_hs_clk0 / S_hs_clk1 之间选出来的。一旦切到没插模组的那一路，
//    S_hs_rx_clk 直接停摆 —— RX 的 AXIS 输出侧状态机被冻在"行中途"。
//    再切回来之后: tvalid 照常出(E9 在涨)、tlast 再也不出(E6 恒 0)、
//    ui_image_correction 的 O_line_groups 恒 0(E4/E5 = 0) =>
//    dbuf 写侧永不轮转(E2 = 0) => 画面永远停在同一帧。
//    现象极具欺骗性: fps 显示 60、快照 24 万字节都正常，
//    只有两帧快照 md5 完全一样才能看出来。
//
//  ⚠ 复位窗放在 25MHz 域（S_pll_lock 域），不依赖任何 RX 恢复时钟，
//    所以 RX 被复位 -> 没时钟 -> 复位照样能按时释放，不会死锁。
//    这就是下面 X_mipi_csi_rx 注释里说的"复位只能依赖 25MHz 域"。
//
//  ⚠ 触发源用 S_clk_sel_r 而不是 S_rx_sel:
//    mux 实际选哪一路取决于 S_clk_sel_r = dual_eff ? 0 : rx_sel，
//    所以 dual_eff 变化导致的换源也必须复位（单目<->双目切换）。
//--------------------------------------------------------------------------
// (S_rx_sel_d / S_src_chg 已在前部信号区声明, 这里只放逻辑)
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) S_rx_sel_d <= 1'b0;
	else             S_rx_sel_d <= S_rx_sel;
end
assign S_src_chg = (S_rx_sel != S_rx_sel_d);   // 配置位变化(给下游复位窗用)

reg  S_clk_sel_d;
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) S_clk_sel_d <= 1'b0;
	else             S_clk_sel_d <= S_clk_sel_r;
end
wire S_clk_chg = (S_clk_sel_r != S_clk_sel_d);   // 时钟源真的换了

// 20 ms @ 25MHz。够 RX 的 HS 检测 + byte 对齐重新跑一遍，
// 又远短于下面的 120ms 写侧窗，不会互相对抗。
localparam [19:0] SRC_RX_RST_CYCLES = 20'd500_000;
reg  [19:0] S_src_rx_hold;
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock)                   S_src_rx_hold <= 20'd0;
	else if (S_clk_chg)                S_src_rx_hold <= SRC_RX_RST_CYCLES;
	else if (S_src_rx_hold != 20'd0)   S_src_rx_hold <= S_src_rx_hold - 20'd1;
end
wire S_src_rx_rst = (S_src_rx_hold != 20'd0);

reg  [1:0]  S_res_chg_d;
reg  [23:0] S_res_hold25;
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) begin
		S_res_chg_d  <= 2'b00;
		S_res_hold25 <= 24'd0;
	end else begin
		S_res_chg_d <= {S_res_chg_d[0], S_res_chg};
		if (S_res_chg_d == 2'b01)          S_res_hold25 <= RES_RST_CYCLES;
		else if (S_src_chg || S_clk_chg)   S_res_hold25 <= SRC_RST_CYCLES;  // 2026-10-21 换源
		else if (S_res_hold25 != 24'd0)    S_res_hold25 <= S_res_hold25 - 24'd1;
	end
end
wire S_res_win25 = (S_res_hold25 != 24'd0);      // 25MHz 域的"切换中"电平

reg [1:0] S_res_win_pclk, S_res_win_rx, S_res_win_byte;
always @(posedge S_pclkx1 or negedge S_pll_lock) begin
	if (!S_pll_lock) S_res_win_pclk <= 2'b00;
	else             S_res_win_pclk <= {S_res_win_pclk[0], S_res_win25};
end
always @(posedge S_hs_rx_clk or negedge S_pll_lock) begin
	if (!S_pll_lock) S_res_win_rx <= 2'b00;
	else             S_res_win_rx <= {S_res_win_rx[0], S_res_win25};
end
// 2026-10-21 双目: cam1 裁剪模块现在与 cam0 同域(都是 S_hs_rx_clk),
// 但复位窗仍单独同步一份, 方便以后真要做双时钟时直接切。
reg [1:0] S_res_win_rx1;
always @(posedge S_hs_rx_clk or negedge S_pll_lock) begin
	if (!S_pll_lock) S_res_win_rx1 <= 2'b00;
	else             S_res_win_rx1 <= {S_res_win_rx1[0], S_res_win25};
end
always @(posedge S_dsi_byte_clk or negedge S_pll_lock) begin
	if (!S_pll_lock) S_res_win_byte <= 2'b00;
	else             S_res_win_byte <= {S_res_win_byte[0], S_res_win25};
end

// ⚠ 这三个只能写 assign, 不能写 "wire X = ..." —— 它们已在前部信号区声明过
//   (wire S_res_rstn_rx1; 等), 再写一遍 "wire ... =" 就是重复声明。
//   TD 碰巧容忍, 但 iverilog 直接 error, 挡住本地语法检查。
assign S_res_rstn_rx   = RES_RST_TX_SIDE ? ~S_res_win_rx[1]   : 1'b1;
assign S_res_rstn_rx1  = RES_RST_TX_SIDE ? ~S_res_win_rx1[1]  : 1'b1;
assign S_res_rstn_byte = ~S_res_win_byte[1];

//=============================================================================
//  V30 (2026-10-17): 模式切换时必须也复位 ui_dbuf + ui_FDMA
//
//  现场现象（用户实测）:
//      刚上电 → 1080p 正常
//      切 4K  → 画面撕裂
//      再切回 1080p → 画面上下/左右错位, 或者直接死机
//
//  根因: `X_ui_dbuf.I_ui_rstn` 和 `X_ui_FDMA.M_AXI_ARESETN` 原来都只接
//        `S_ddr_init_cal_done` —— 只在 DDR 校准完成那一次释放, 此后再也不复位。
//        但它们的 `I_W_XSIZE / I_R_XSIZE / I_*_YSIZE / *_XSTRIDE` 是随
//        RES_MODE 变的。切换后 FDMA 状态机 / `w_ycnt,r_ycnt` /
//        `wdiv_cnt,rdiv_cnt` / 乒乓缓冲指针全保留旧模式的相位
//        ⇒ 相位错(错位), 或 FSM 等一个永远不来的 burst 数(死机)。
//
//  做法: 切换时把这两个也复位。关键两点 ——
//    (1) 【延后 2ms】再复位: 先让上游写侧和 VTC 读请求都停下来, 避免在
//        AXI 突发中途复位 master, 那样 DDR 侧可能挂在等数据 -> 真死机。
//    (2) dbuf 和 FDMA 必须【同时】进出一致(厂商注释就写了
//        "和FDMA AXI复位一致"), 所以两者接同一个 S_ud_rstn。
//        复位一直保持到 500ms 切换窗结束。
//=============================================================================
localparam [17:0] UD_RST_DLY = 18'd50_000;      // 2 ms @ 25MHz

reg  [17:0] S_ud_dly;
reg         S_ud_rst_win;                       // 1 = 正在复位 dbuf/FDMA
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock)                     S_ud_dly <= 18'd0;
	// 2026-10-26: **换 CSI 源也必须复位 dbuf + FDMA**。
	//   原来这里只认 S_res_chg_d(切分辨率), 换源时虽然 S_res_hold25 开了
	//   120ms 窗、写侧/读侧/byte 域都复位了, 但 dbuf/FDMA 这一路没动 ->
	//   FDMA 停在旧源的 AXI 突发中途 -> 写侧永久堵死, 而 VTC 照旧自由跑 ->
	//   板上现象: MIPI_CSI2 ERR1 0x1000000(crc,vc:0) / 0x10(fs/fe mis) 刷屏,
	//   rkcif 报 "csi size err size:0x0", 画面卡死且只能重烧 bit 才能恢复。
	//   ⚠ 只加在这一处: 绝不能加进 S_res_evt / S_reload_wait —— 那两个会触发
	//     传感器整表重写 + D-PHY 长复位(>500ms), 换源时两颗传感器都没停,
	//     不需要也不应该重写它们。
	else if (S_res_chg_d == 2'b01 ||
	         S_src_chg || S_clk_chg)     S_ud_dly <= 18'd1;        // 从切换沿开始计时
	else if (S_ud_dly == 18'd0)          S_ud_dly <= 18'd0;
	else if (S_ud_dly <  UD_RST_DLY)     S_ud_dly <= S_ud_dly + 18'd1;
	else                                 S_ud_dly <= 18'd0;        // 到点停
end

always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock)                     S_ud_rst_win <= 1'b0;
	else if (S_ud_dly == UD_RST_DLY)     S_ud_rst_win <= 1'b1;     // 2ms 后开始复位
	else if (!S_res_win25)               S_ud_rst_win <= 1'b0;     // 500ms 窗结束释放
end

// 异步置位 / 同步释放 到 S_dfi_clk 域(标准做法, 避免释放沿亚稳态)
wire S_ud_rstn_async = S_ddr_init_cal_done & ~S_ud_rst_win;
reg  [2:0] S_ud_rstn_dfi;
always @(posedge S_dfi_clk or negedge S_ud_rstn_async) begin
	if (!S_ud_rstn_async) S_ud_rstn_dfi <= 3'b000;
	else                  S_ud_rstn_dfi <= {S_ud_rstn_dfi[1:0], 1'b1};
end
wire S_ud_rstn = S_ud_rstn_dfi[2];

//=============================================================================
//  V24 (2026-10-16): 分辨率切换时还要做两件事 —— 否则 4K 根本出不来
//
//  (1) 让传感器换读出模式。1080p 跑的是 2x2 binning, 4K 要 all-pixel; 差的
//      27 个寄存器(0x3020/21/22、0x3024/25 VMAX、0x3028 HMAX、0x3033 SYS_MODE
//      以及 0x4004..0x4074 整套 MIPI D-PHY 发送时序)**只在主表相位才会被写**,
//      所以必须请 ui_cfg_imx415 把整张表重跑一遍。
//  (2) D-PHY RX 必须重新锁定: 4K 改了那套 D-PHY 时序寄存器, lane 速率变了。
// ============================================================================
// ---- 延时 ~32 拍再发“全表重载”, 并且把脉宽展到 16 拍 ----
//   延时: 让上面那个 24MHz 同步器先把新的 mode 稳住, 否则重载出去了 mode 还没到。
//   展宽: 25MHz 域 1 拍脉冲跨到 24MHz 域会被整拍蹭掉, 必须拉长。
reg [6:0] S_res_evt;
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock)               S_res_evt <= 7'd0;
	else if (S_res_chg_d == 2'b01) S_res_evt <= 7'd48;      // 32 延时 + 16 展宽
	else if (S_res_evt != 7'd0)    S_res_evt <= S_res_evt - 7'd1;
end
wire S_full_reload25 = (S_res_evt != 7'd0) && (S_res_evt <= 7'd16);

reg [2:0] S_reload_sync24;
always @(posedge S_clk_24m or negedge S_pll_lock) begin
	if (!S_pll_lock) S_reload_sync24 <= 3'b000;
	else             S_reload_sync24 <= {S_reload_sync24[1:0], S_full_reload25};
end
// S_full_reload 的声明已上移到 ui_cfg_imx415 例化之前 (见 V24 那一节)
assign S_full_reload = (S_reload_sync24[2:1] == 2'b01);   // 24MHz 域的单拍脉冲

// ---- 同步 O_cfg_done 到 25MHz 域 ----
//   用它判断"传感器全表重写"什么时候完成 —— 比猜时长靠谱得多。
reg [2:0] S_cfg_done_sync25;
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) S_cfg_done_sync25 <= 3'b000;
	else             S_cfg_done_sync25 <= {S_cfg_done_sync25[1:0], S_cam_cfg_done};
end
wire S_cfg_done_25 = S_cfg_done_sync25[2];

//=============================================================================
//  V25 (2026-10-16): D-PHY RX 复位 —— 用**完成信号**触发, 不再猜时长
//-----------------------------------------------------------------------------
//  两轮实测教训(都是切 4K 后 RX 彻底停住, FRAME_CNT 56fps -> 0):
//    第一轮: 复位保持 60ms  -> 死
//    第二轮: 复位保持 250ms -> 还是死
//  因为"该等多久"取决于两件都不固定的事:
//    ① ui_cfg 把传感器整张初始化表写完 (201 个寄存器 ~78ms, 加绕圈共 ~99ms)
//    ② 传感器自己把 PLL 锁上、重启码流 (厂商资料没给, 只能实测)
//  猜时长永远不保险。所以改成:
//    复位一直保持 -> 等 O_cfg_done 上升(=主表写完) -> 再等 150ms -> 才释放
//  另外加 1.2s 超时兜底: 万一完成信号没来(比如连写两次 RES_MODE 把边沿吃掉),
//  也不会把整个视频通路永久摁在复位里 (那样只能重烧 bit 才能救)。
//=============================================================================
localparam [23:0] DPHY_RST_MARGIN  = 24'd3_750_000;   // 150 ms @ 25MHz
localparam [24:0] DPHY_RST_TIMEOUT = 25'd30_000_000;  // 1.2 s  @ 25MHz

reg  [1:0]  S_cfg_done_edge;
reg         S_reload_wait;
reg  [23:0] S_after_done_cnt;
reg  [24:0] S_dphy_rst_to_cnt;
reg         S_dphy_rx_rst = 1'b0;

always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) begin
		S_cfg_done_edge   <= 2'b00;
		S_reload_wait     <= 1'b0;
		S_after_done_cnt  <= 24'd0;
		S_dphy_rst_to_cnt <= 25'd0;
		S_dphy_rx_rst     <= 1'b0;
	end else begin
		S_cfg_done_edge <= {S_cfg_done_edge[0], S_cfg_done_25};
		if (S_res_chg_d == 2'b01) begin
			// 切换请求: 把 D-PHY RX 按住, 开始等"主表写完"
			S_reload_wait     <= 1'b1;
			S_dphy_rx_rst     <= 1'b1;
			S_after_done_cnt  <= 24'd0;
			S_dphy_rst_to_cnt <= DPHY_RST_TIMEOUT;
		end else if (S_reload_wait) begin
			if (S_cfg_done_edge == 2'b01) begin
				// 主表写完 -> 再留 150ms 给传感器锁相/重启码流
				S_reload_wait    <= 1'b0;
				S_after_done_cnt <= DPHY_RST_MARGIN;
			end else if (S_dphy_rst_to_cnt != 25'd0) begin
				S_dphy_rst_to_cnt <= S_dphy_rst_to_cnt - 25'd1;
			end else begin
				S_reload_wait <= 1'b0;   // 超时兜底: 强行进入余量计时
			end
		end else if (S_after_done_cnt != 24'd0) begin
			S_after_done_cnt <= S_after_done_cnt - 24'd1;
		end else begin
			S_dphy_rx_rst <= 1'b0;       // 释放
		end
	end
end

//=============================================================================
// 2026-10-20 子卡去掉 LP 抽头后的 CSI-2 接收: 换成 LP-free 的 mipi_csi_rx
//
// 背景: FMC_VID005 子卡按厂家方案去掉 CSI 的 100R LP 抽头
//   (R5/R9/R11/R15/R17/R21/R23/R27/R29/R33) 之后, FPGA 的 I_data_lp_p/n
//   变成悬空, 只能读到恒定的 LP-11; 原来那套 mipi_dphy_rx_over_lvds_wrapper
//   的 HS/LP 状态机必须看到 LP 跳变 (11->01->00) 才能定位包边界, 所以永远
//   解不出帧 (实测: 心跳正常, MIPI 出流 245.9MB/s, 但 FRAME_CNT 恒为 0)。
//
// 新方案 (源码来源: 07_异构方案/.../uisrc/03_ip/mipi_csi_2, 已拷到
//   uisrc/03_ip/mipi_csi_lpfree/):
//     只用 5 对差分 (CLK + D0~D3) + 一路参考时钟:
//       PH1_LOGIC_DYNAMIC_IDELAY + PH1_LOGIC_IDDRx2 做 4:1 解串;
//       auto_delay_ctl 用 eye-scan 自动挑采样 tap;
//       csi_rx_packet_handler 直接在字节流里找 CSI-2 包头定位 burst —— 不用 LP。
//     输出 40bit RAW10 (4 像素/时钟), 直接接 ui_image_correction,
//     所以原来的 ui_csi_unpacket_4lane + ui_raw10_unpacket_4lane 一起删掉。
//
// 三个坑 (都写在代码里, 别改):
//   1) I_debug_button 默认必须为 1'b1 (上拉按键未按下)。
//      接 0 会在复位后产生一次 11->01 的边沿, 把 RX 锁进 manual delay 模式,
//      自动 eye-scan 就不再执行了。
//      2026-10-21: 改由寄存器 0xD9 驱动 (idle=1)。写一次 0xD9 = 按一下再松开,
//      RX 就 tap+1 —— 用来在板上逐 tap 抓图, 直接测眼图中心。
//   2) m_axis_video_tready 恒 1。该 AXIS 的 tvalid = tready & ~empty,
//      下游没有反压 (和原来的 raw10 通路一致)。
//   3) 参考时钟用 I_ddr_clk (T13, 100MHz LVDS)。07 工程用 PLL 出 150MHz,
//      但 ref clock 只被 csi_rx_clock_det 用来计时 (判断 HS 时钟还在不在),
//      100MHz 只影响"判丢时钟"的时间常数, 不影响采样与 eye-scan。
//=============================================================================
// ⚠ 复位只能依赖 25MHz 域的 S_pll_lock / S_dphy_rx_rst / S_src_rx_rst。
//   绝不能把 S_res_rstn_rx (它是 S_hs_rx_clk 域里 2 级同步出来的寄存器)
//   接进来: S_hs_rx_clk 就是 RX 自己分频出来的, RX 被复位 -> 没时钟 ->
//   那个同步器永远不更新 -> 复位永远不放 -> 死锁。
assign S_rx_rstn = S_pll_lock & ~S_dphy_rx_rst & ~S_src_rx_rst;

// 2026-10-21: 手动 tap 步进按钮 (来自 cfg_ctrl_top 的 0xD9, idle=1)
wire S_dbg_btn;

//--------------------------------------------------------------------------
//  RX #0 —— cam0 (子卡 J2 / CSI 座)
//--------------------------------------------------------------------------
mipi_csi_rx #(
	.MIPI_LAN        ( 4      ),
	.DEVICE          ( "PH1A" )
)X_mipi_csi_rx(
	.I_debug_button        ( S_dbg_btn  ),
	.I_ref_clock           ( I_ddr_clk   ),
	.I_clk_hs_rx_p         ( I_clk_hs_p  ),
	.I_reset_n             ( S_rx_rstn   ),
	.I_hs_data_p           ( I_data_hs_p ),
	.I_enable              ( 1'b1        ),

	.O_hs_div_clk          ( S_hs_clk0   ),

	// ★ 2026-10-28: 各自接自己的恢复时钟 —— 双目同时采集后不再需要时钟 mux。
	//   RX 内部有跨时钟 FIFO, aclk 就是它自己的 O_hs_div_clk 最干净。
	.m_axis_video_aclk     ( S_hs_clk0    ),
	.m_axis_video_aresetn  ( S_rx_rstn     ),
	.m_axis_video_tready   ( 1'b1          ),
	.m_axis_video_tuser    ( S_rx0_tuser   ),
	.m_axis_video_tlast    ( S_rx0_tlast   ),
	.m_axis_video_tvalid   ( S_rx0_tvalid  ),
	.m_axis_video_tdata    ( S_rx0_tdata   ),

	// 调试总线 -> I2C 只读寄存器 0xD6/0xD7/0xD8
	.O_auto_delay_done     ( S_rx_autodone     ),
	.O_dbg_mipi            ( S_rx_dbg_mipi     ),
	.O_dbg_delay           ( S_rx_dbg_delay    ),
	.O_dbg_best_len        ( S_rx_dbg_best_len )
);

//--------------------------------------------------------------------------
//  RX #1 —— cam1 (子卡 J3 / 原 DSI 座)
//
//  ⚠ 必须是一个**独立实例**：TD 的 SYN-8207 要求 IDDR/IDELAY 直连 PAD，
//    在 PAD 和原语之间插 mux 会直接报 "can't be mapped into PAD"（0x4510 实测）。
//  ⚠ 引脚顺序按子卡原理图 P01_CON：
//      I_clk1_hs_p = E16 (FMC CLK1_M2C_P)
//      I_data1_hs_p[0] = F18 (LA29_P) -> DSI_HS_D0P
//      I_data1_hs_p[1] = K16 (LA31_P) -> DSI_HS_D1P
//      I_data1_hs_p[2] = D17 (LA30_P) -> DSI_HS_D2P
//      I_data1_hs_p[3] = J17 (LA33_P) -> DSI_HS_D3P
//--------------------------------------------------------------------------
mipi_csi_rx #(
	.MIPI_LAN        ( 4      ),
	.DEVICE          ( "PH1A" )
)X_mipi_csi_rx1(
	.I_debug_button        ( S_dbg_btn   ),
	.I_ref_clock           ( I_ddr_clk   ),
	.I_clk_hs_rx_p         ( I_clk1_hs_p ),
	.I_reset_n             ( S_rx_rstn   ),
	.I_hs_data_p           ( I_data1_hs_p),
	.I_enable              ( 1'b1        ),

	.O_hs_div_clk          ( S_hs_clk1   ),

	// 2026-10-21: 两路 AXIS 输出时钟都用 S_hs_rx_clk (与 0x4601 一致)。
	//   选中的那一路的恢复时钟就是 S_hs_rx_clk 的来源，所以下游全部同域；
	//   没选中的那一路靠 RX 内部 FIFO 做 CDC，数据丢弃即可。
	.m_axis_video_aclk     ( S_hs_clk1    ),
	.m_axis_video_aresetn  ( S_rx_rstn     ),
	.m_axis_video_tready   ( 1'b1          ),
	.m_axis_video_tuser    ( S_rx1_tuser   ),
	.m_axis_video_tlast    ( S_rx1_tlast   ),
	.m_axis_video_tvalid   ( S_rx1_tvalid  ),
	.m_axis_video_tdata    ( S_rx1_tdata   ),

	.O_auto_delay_done     ( S_rx1_autodone     ),
	.O_dbg_mipi            ( S_rx1_dbg_mipi     ),
	.O_dbg_delay           ( S_rx1_dbg_delay    ),
	.O_dbg_best_len        ( S_rx1_dbg_best_len )
);

//--------------------------------------------------------------------------
//  2026-10-21: 两颗传感器的"同步启动"
//  双目交替要求两路帧/行对齐 —— 用"同时拉低两颗 RSTn、再同时重跑初始化表"
//  把它们拉到同一个起点。平时（没写 0xDB bit1）O_rst_n=1、cfg 不压，
//  和原来"RSTn 恒高、cfg 立即启动"完全一致，不影响单目上电即正常。
//--------------------------------------------------------------------------
sensor_sync_start #(
	.HOLD_CYCLES (500_000),     // 20ms @ 25MHz
	.CNTW        (20)
) u_sensor_sync (
	.I_clk        (I_sysclk_25m),
	.I_rst_n      (S_pll_lock  ),
	.I_start      (S_dual_start),
	.O_rst_n      (S_sensor_rst_n),
	.O_cfg_restart(S_cfg_hold  )
);

//--------------------------------------------------------------------------
//  时钟二选一 + 强制过 BUFG
//  ★ 不做 BUFG: S_ud_wclk 会落到普通布线网 -> 写侧偏斜丢拍 -> 画面向上滚动
//    (0x450E 实测)。这里 S_rx_sel 是准静态寄存器，只有切换瞬间会毛刺，
//    切换后立刻有 120ms 写侧复位窗兜住。
//--------------------------------------------------------------------------
// ★ 2026-10-28: 双目**同时**采集后不再有"选源"，两路 RX 各自跑自己的恢复时钟，
//   拼接模块 (dual_stitch) 是唯一的跨时钟点。
//
//   像素域时钟 = **PLL 现成的 70MHz 输出 (S_clk_70m)**，不再用 toggle-FF 分频：
//     - 70MHz x 4px = 280 Mpx/s >= 需要的 248.8 (余量 12.6%)
//     - 拼接读侧 964 拍/行 @70MHz = 13.77us < 源行 14.81us (余量 7%)
//     - 它是真 PLL 输出: derive_clocks 会自动建时钟、set_clock_groups 能引用。
//       (toggle FF + BUFG 生成的时钟, TD 的 create_clock 按引脚名找不到 -> 整条
//        set_clock_groups 命令失败 -> 所有 CDC 被当同步路径算 -> 假违例 −6.8ns)
	// JPEG 编码器时钟: V47.14 起回退到 S_hs_rx_clk(70MHz), 见下方说明
//   ★ 2026-10-28: 双引擎的吞吐账 ——
//     3840x1080 = (3840/16)x(1080/8) = 240x135 = 32400 MCU
//     双引擎每个编 16200 MCU, 有损 150 clk/MCU
//     @147.5MHz: 16200 x 150 / 147.5MHz = 16.48ms -> 60.6fps (目标 60, 但时序不收敛)
//     @ 70MHz : 16200 x 150 / 70MHz    = 34.7ms  -> 28.8fps (本版可落地实测用)
//   原来用 pclkx1/4 = 36.875MHz 的 toggle-FF 分频, 只能到 ~15fps;
//   而且 toggle FF 生成的时钟 SDC 里 create_clock 按引脚名找不到, 等于不受时序检查。
// 2026-10-28 V47.14: 编码器时钟回退到像素域 S_hs_rx_clk(70MHz)
//   原因: 挂 S_pclkx1(147.5MHz) 时实测最差路径 ~14.8ns, 布线后 WNS -8 ~ -12ns,
//   编码结果不可信。本版目标是“能落地实测 JPEG 直通”, 所以优先保证正裕量:
//     16200 MCU x 150 clk / 70MHz = 34.7ms -> 28.8fps (双引擎并行)
//   70MHz 下预算 14.29ns vs 路径 14.8ns, 只差 0.5ns —— 叠加本轮资源优化
//   (AWB 串行除法 -5400FF / demosaic -12ERAM / 7x7 -10ERAM) 降拥塞后有望转正。
//   后续把 huff 数值通路拆 2~3 级流水后, 再改回 S_pclkx1 冲 60fps。
//
// ★ 2026-10-28 V47.15: 切回 S_pclkx1 (147.5MHz) 冲 60fps 验证
//   16200 MCU x 151.3 clk / 147.5MHz = 16.62ms -> 60.19fps (双引擎并行)
//   顺带解决 gate 断粮: 147.5MHz 下编码速度追平 60fps 输入, 不会再出现
//   "编到一半下个 SOF 把 gate 关掉 -> linebuf 断粮 -> 卡在 T_WGRP" 的死锁。
//   70MHz 版实测 0xA0(上一帧字节数) 恒 0 = 一帧都没完成, 就是这个原因。
//   时序关键: V47.14 那次最差路径 13.45ns 里 net 占 10.21ns (76%),
//   纯粹是布线绕远 —— 本轮配 place/route 高 effort 压拥堵, 不拆流水。
//
// ★★★ 2026-10-28 V47.15 结论: 147.5MHz 已验证不可行, 回退 70MHz ★★★
//   syn 后 S_pclkx1->S_pclkx1: Min Period 16.503ns, Fmax 60.595MHz, SWNS -9.724ns,
//   3997/22579 个端点违例(17.7%), 瓶颈 X_jpeg_l/u_huff/state_reg[1] -> kk_reg[1]。
//   拆流水只提频率不提吞吐(同一份工作摊到更多拍), 对帧率无益。
//   业界参照: ultraembedded/core_jpeg 商品核在 Xilinx 7 系也只有 75MHz ——
//   JPEG 熵编码天生串行, 147.5MHz 不是"再优化一下"能到的。
//   => 60fps 只能靠**增加并行度(4 引擎)**, 频率维持 70MHz。
assign S_enc_clk = S_hs_rx_clk;

// 已无选源: 保持为 0, 让旧的换源复位窗口逻辑永远不触发
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) S_clk_sel_r <= 1'b0;
	else             S_clk_sel_r <= 1'b0;
end

// 下游像素域 = 拼接输出时钟 (70MHz, PLL 直出)
assign S_st_clk    = S_clk_70m;
assign S_hs_rx_clk = S_st_clk;

//--------------------------------------------------------------------------
//  ⚠ 0x4700 曾经在这里给 cam1 额外插了一个 BUFG (S_hs_clk1_raw -> S_hs_clk1)，
//    让 ui_image_correction1 跑在 cam1 自己的时钟上。**那是错的，已删除**：
//    dual_frame_sched 内部是用 I_clk(=S_hs_rx_clk) 采样 I_d1/v1/u1/l1 的，
//    只要 cam1 那一支不自始至终跟 S_hs_rx_clk 同域，tuser 就会丢，
//    dbuf 写状态机的 w_fs 不来 -> 三帧缓存不轮转 -> 画面冻结。
//    正确做法就是 0x4601 原本的设计：两路 RX 的 m_axis_video_aclk 都用
//    S_hs_rx_clk，选中的那一路就是它的时钟源，整条下游天然同域。
//--------------------------------------------------------------------------

//--------------------------------------------------------------------------
//  把选源位同步进 RX 时钟域
//--------------------------------------------------------------------------
// ⚠ 若选中的那一路没有摄像头(没有 HS 时钟)，S_hs_rx_clk 会停摆，
//   这个同步器就不动了 —— 无所谓: 换回有信号的源时 S_src_rx_rst 会把
//   整颗 RX(含它的 AXIS 输出状态机)重新复位一遍，起来就是干净的。
always @(posedge S_hs_rx_clk or negedge S_pll_lock) begin
	if (!S_pll_lock) S_rx_sel_rx_s <= 2'b00;
	else             S_rx_sel_rx_s <= {S_rx_sel_rx_s[0], S_rx_sel};
end
assign S_rx_sel_rx = S_rx_sel_rx_s[1];

//--------------------------------------------------------------------------
//  两路各自裁剪（互不相干，各在自己的恢复时钟域）
//
//  为什么要两个 ui_image_correction：
//    双目交替模式下两路都要独立地"按自己的帧首对齐 + 裁出有效区"，
//    否则交替时下游看到的两路行/帧相位会打架。
//    这个模块很便宜（77 LUT / 0 ERAM / 0 DSP），复制一份不影响资源。
//
//  调试总线**不按源选**：0xD6/D7/D8 固定是 cam0，0xDD/DE/DF 固定是 cam1。
//    原因：按源选的话同步器挂在恢复时钟上，切到没摄像头的源时时钟停摆，
//    选源位会卡住，寄存器一直显示上一个源的数据（实测踩过）。
//--------------------------------------------------------------------------
assign S_crop0_frame_start = S_rx0_tvalid & S_rx0_tuser;
assign S_crop1_frame_start = S_rx1_tvalid & S_rx1_tuser;
// 供 cfg_ctrl_top 统计"传感器真实帧率"：用 cam0 的帧首（双目下仍是传感器的 60fps）
assign S_csi_frame_start   = S_crop0_frame_start;


//图像大小裁剪模块 (cam0)
ui_image_correction #(
    .DATA_WIDTH  (40),
    .TDEST_WIDTH (10)
)X_ui_image_correction
(
    .O_line_groups    (S_line_groups     ),  // V21 诊断: 每行像素组数
    // ★ 2026-10-28: 本模块回到 cam0 自己的恢复时钟域 (不再共用 mux 时钟)
    .I_clk            (S_hs_clk0		  ),
    .I_rst_n          (S_pll_lock		  ),
    // 单目裁剪宽度固定 1920 (与下游 S_h_active=3840 分开)
    .I_img_width      (S_cam_h		  ),
    .I_img_height     (S_v_active		  ),
    // V39: 垂直起始裁剪 (4K=35, 1080p=19)
    .I_v_start        (S_v_start		  ),
    // 2026-10-21: 每行实际组数 (1080p=486 / 4K=966), 不依赖行间空闲分行
    .I_grp_per_line   (S_grp_per_line     ),
	
    .I_raw_data       (S_rx0_tdata        ),       
    .I_raw_valid      (S_rx0_tvalid       ),     
    .I_raw_frame_start(S_crop0_frame_start),
    .I_raw_frame_end  (1'b0               ),
    
    .O_raw_tdata 	  (S_crop0_tdata 	  ),
    .O_raw_tlast 	  (S_crop0_tlast 	  ),
    .O_raw_tvalid	  (S_crop0_tvalid	  ),
    .O_raw_tuser 	  (S_crop0_tuser 	  )

);

//图像大小裁剪模块 (cam1)
//  ⚠ 时钟必须是 S_hs_rx_clk。这个模块靠 I_raw_valid 数行/列, 再对比
//    I_raw_frame_start( = S_rx1_tvalid & S_rx1_tuser ) 复位行号。
//    一旦它的时钟和 S_rx1_* (m_axis_video_aclk = S_hs_rx_clk) 不同域,
//    frame_start 会漏採 -> v_cnt 失控 -> O_raw_tuser 永不出来 -> 下游
//    dbuf 写状态机不再推进 -> 画面冻结。
ui_image_correction #(
    .DATA_WIDTH  (40),
    .TDEST_WIDTH (10)
)X_ui_image_correction1
(
    .O_line_groups    (S_line_groups1    ),
    // ★ 2026-10-28: 本模块回到 cam1 自己的恢复时钟域
    .I_clk            (S_hs_clk1		  ),
    .I_rst_n          (S_pll_lock		  ),
    .I_img_width      (S_cam_h		  ),
    .I_img_height     (S_v_active		  ),
    .I_v_start        (S_v_start		  ),
    .I_grp_per_line   (S_grp_per_line     ),
    .I_raw_data       (S_rx1_tdata        ),
    .I_raw_valid      (S_rx1_tvalid       ),
    .I_raw_frame_start(S_crop1_frame_start),
    .I_raw_frame_end  (1'b0               ),
    .O_raw_tdata 	  (S_crop1_tdata 	  ),
    .O_raw_tlast 	  (S_crop1_tlast 	  ),
    .O_raw_tvalid	  (S_crop1_tvalid	  ),
    .O_raw_tuser 	  (S_crop1_tuser 	  )
);

//=============================================================================
//  双目【同时】采集 + 整行乒乓 + 左右拼接 (2026-10-28)
//
//  替换原来的 dual_frame_sched (逐帧交替, 每目 30fps)。现在两路每一行都同时
//  进各自的 FIFO, 读侧拼成 "左半 = cam1 + 右半 = cam0" 的 3840 宽一行, 输出
//  仍是 4px/clk / 40bit, 所以 ui_isp_top 以下全部不用改位宽。
//
//  ⚠ 时钟: 两路写侧各用自己的恢复时钟 (S_hs_clk0/S_hs_clk1), 读侧是 S_hs_rx_clk
//     (= S_st_clk = 70.238MHz)。这是整个工程唯一的跨时钟点。
//  ⚠ 掉一路 (没插模组/RX 没锁) 时该半幅填黑, 另一半照常跑 —— 不会再整链死锁。
//=============================================================================
wire [15:0] S_st_l_ovf, S_st_r_ovf, S_st_l_starve, S_st_r_starve, S_st_lines;
wire [23:0] S_st_frames;

dual_stitch #(
    .HGRP       (480),      // 1920 px / 4 px + 4px/clk = 480 组
    .V_ACTIVE   (1080),
    .FIFO_AW    (11),       // 每源 2048 word ≈ 4.2 行
    .SWAP       (0),        // ★ 左 = cam1, 右 = cam0 (用户指定)
    .STARVE_MAX (2400)      // @70.238MHz ≈ 34.2us ≈ 2.3 行
) X_dual_stitch (
    .l_clk     (S_hs_clk1        ),
    .l_rst_n   (S_pll_lock       ),
    .l_valid   (S_crop1_tvalid   ),
    .l_data    (S_crop1_tdata    ),
    .l_user    (S_crop1_tuser    ),
    .l_last    (S_crop1_tlast    ),
    .r_clk     (S_hs_clk0        ),
    .r_rst_n   (S_pll_lock       ),
    .r_valid   (S_crop0_tvalid   ),
    .r_data    (S_crop0_tdata    ),
    .r_user    (S_crop0_tuser    ),
    .r_last    (S_crop0_tlast    ),
    .o_clk     (S_hs_rx_clk      ),
    .o_rst_n   (S_pll_lock       ),
    .o_valid   (S_axis_tvalid    ),
    .o_data    (S_axis_tdata     ),
    .o_user    (S_axis_tuser     ),
    .o_last    (S_axis_tlast     ),
    .st_l_ovf    (S_st_l_ovf     ),
    .st_r_ovf    (S_st_r_ovf     ),
    .st_l_starve (S_st_l_starve  ),
    .st_r_starve (S_st_r_starve  ),
    .st_lines    (S_st_lines     ),
    .st_frames   (S_st_frames    )
);

// 已无"哪一目"的概念 (两目同时在流里), 帧标记固定按 0 打
assign S_out_src = 1'b0;
// 旧逐帧调度器的输出, 保留声明避免其它模块引用时悬空
assign S_dual_eff = 1'b0;



//米联客ISP图像处理模块
ui_isp_top X_ui_isp_top (
	.I_clk		     (S_hs_rx_clk		),
	// V23: ISP 内部也有按宽高走的行/列计数器, 一起复位
	.I_rst_n         (S_pll_lock & S_res_rstn_rx		),
	.I_img_width     (S_h_active		),
	.I_img_height    (S_v_active		),
	.I_is_4k         (S_is_4k			),  // V40: 4K=RGGB, 1080p 由 0xDA 选
	.I_bayer_sel     (S_bayer_sel		),  // 2026-10-21: 0=RGGB 1=GRBG 2=GBRG 3=BGGR
	.I_tlast         (S_axis_tlast 		),
	.I_tuser         (S_axis_tuser 		),
	.I_tdata         (S_axis_tdata 		),
	.I_tvalid        (S_axis_tvalid		),
	.I_tdest         (					),
	.O_tready        (S_ISP_O_tready	),
	.O_tdata         (S_ISP_O_tdata 	),
	.O_tlast         (S_ISP_O_tlast 	),
	.O_tuser         (S_ISP_O_tuser 	),
	.O_tvalid        (S_ISP_O_tvalid	),
	.I_tready        (					)
  );


//=============================================================================
//  预处理流水线 P4/P5/P6 (Sobel / 阈值分割 / 形态学)
//
//  插入位置: ui_isp_top 输出 (RGB888x4) 与 rgb_to_yuv422_quad 之间。
//  配置由反向传参链路 (cfg_ctrl_top) 给出, 经 2 级同步进入本时钟域。
//  ⚠ 不改变行结构 (1080 行进 1080 行出) —— 帧首两行纵向邻域无效时用当前行
//    顶替, 而不是丢行。丢行会让下游色度平面整体错位。
//=============================================================================
//  ⚠ S_pp_* 的声明已上移到文件前部 (rgb_to_yuv422_quad 之前)。
//    Verilog 要求先声明后使用; 若声明点晚于使用点, 信号会被隐式声明成
//    1 bit wire (S_pp_tdata 本该 128 bit), TD 报 HDL-7225。
//    本次编译踩过此坑, 勿再下移。
//=============================================================================

preproc_top #(
	.PX_PER_CLK (4)
) u_preproc (
	.clk            (S_hs_rx_clk),
	.rst_n          (S_pll_lock & S_res_rstn_rx),
	.i_h_active     (S_h_active),
	.i_v_active     (S_v_active),
	.i_tvalid       (S_ISP_O_tvalid),
	.i_tuser        (S_ISP_O_tuser),
	.i_tlast        (S_ISP_O_tlast),
	.i_rgb          (S_ISP_O_tdata),
	.i_basic_en     (S_basic_en),
	.i_gray_mode    (S_basic_gray),
	.i_gauss_str    (S_basic_gauss),
	.i_gauss_ker    (S_basic_ker),
	.i_he_str       (S_basic_he),
	.i_he_clip      (S_basic_he_clip),
	.i_linefix      (S_basic_linefix),
	.i_contrast     (S_basic_contrast),
	.i_mode         (S_pp_mode),
	.i_sobel_gain   (S_pp_sobel_sh),
	.i_thresh       (S_pp_thresh),
	.i_morph_sel    (S_pp_morph_sel),
	.i_morph_th     (S_pp_morph_th),
	.i_lap_gain     (S_pp_lap_sh),
	.i_prew_gain    (S_pp_prew_sh),
	.i_emboss_gain  (S_pp_emboss_gain),
	.i_emboss_bias  (S_pp_emboss_bias),
	.o_tvalid       (S_pp_tvalid),
	.o_tuser        (S_pp_tuser),
	.o_tlast        (S_pp_tlast),
	.o_rgb          (S_pp_tdata)
);


//=============================================================================
//  后级: 数字白平衡 + ROI 裁剪
//
//  为什么白平衡放这里: IMX415 是 RAW sensor, 自身没有白平衡寄存器; 本工程用的
//  ui_awb 是**全自动**的 (见 ui_awb.v 端口表, 没有任何手动增益输入)。
//  所以「手动白平衡」只能在像素级做 —— 好处是可调、立即生效。
//  为什么 ROI 不改真实分辨率: ui_vtc 的时序参数是编译期 #() 参数, 运行时改不了。
//  所以做成「中心裁剪 + 填黑边」, 输出仍是 1920x1080, RK 侧完全不用动。
//=============================================================================
preproc_post #(
	.PX_PER_CLK (4)
) u_preproc_post (
	.clk        (S_hs_rx_clk),
	.rst_n      (S_pll_lock & S_res_rstn_rx),
	.i_h_active (S_h_active[11:0]),
	.i_v_active (S_v_active[11:0]),
	.i_tvalid   (S_pp_tvalid),
	.i_tuser    (S_pp_tuser),
	.i_tlast    (S_pp_tlast),
	.i_rgb      (S_pp_tdata),
	.i_wb_r     (S_wb_r),
	.i_wb_b     (S_wb_b),
	.i_mono     (S_mono_pp),
	.i_roi_pct  (S_roi_pct),
	.o_tvalid   (S_post_tvalid),
	.o_tuser    (S_post_tuser),
	.o_tlast    (S_post_tlast),
	.o_rgb      (S_post_tdata)
);


//=============================================================================
//  反向传参链路: I2C 从机 @0x40 + 参数字符堆 (cfg_ctrl_top 内部包含)
//
//  用常开的 25MHz 时钟而不是像素时钟 —— 链路没起来时也能配置。
//  配置信号在 cfg_ctrl_top 内部做 2 级同步后送到像素域。
//=============================================================================
wire S_cfg_scl_i, S_cfg_sda_i, S_cfg_sda_drv;

assign IO_cfg_scl = 1'bz;                        // 从机不做时钟拉伸
assign S_cfg_scl_i = IO_cfg_scl;
assign IO_cfg_sda = S_cfg_sda_drv ? 1'b0 : 1'bz; // 开漏: 1 = 拉低
assign S_cfg_sda_i = IO_cfg_sda;

cfg_ctrl_top #(
	.DEV_ADDR (7'h40)
	// ★ 构建版本号**不再在这里覆盖**。
	//   旧版这里硬写了 `.CFG_VER(16'h4704)`, 会盖掉 cfg_ctrl_top 的 parameter 默认值
	//   —— 2026-10-17 和 2026-10-25 两次都因为“改了一处没改另一处”导致
	//   版本号一直是旧的（2026-10-25 已把三处修复都编进 bit, 板上仍读 0x4704）。
	//   现在唯一真源是 cfg_ctrl_top.v 的 `parameter [15:0] CFG_VER`。
	//   历史版本对照表也放在那里。
) u_cfg_ctrl (
	.i_sys_clk    (I_sysclk_25m),
	.i_sys_rst_n  (1'b1),
	.i_scl        (S_cfg_scl_i),
	.i_sda        (S_cfg_sda_i),
	.o_sda_drive  (S_cfg_sda_drv),
	.i_pix_clk    (S_hs_rx_clk),
	.i_pix_rst_n  (S_pll_lock),
	.i_frame_tuser(S_ISP_O_tuser),
	// V36: 真正的帧首/行尾信号 (S_ISP_O_tuser 实测恒 0, 不能用作计数)
	.i_fs_csi     (S_csi_frame_start),   // CSI-2 FS 短包 -> 传感器真实帧率
	// 2026-10-21 画面冻结定位 (只读 0xE1~0xE3)
	// ★ V53c: 0xE1/0xE3 改为 dual_stitch 的成帧数 (低/中字节), 见下方拼接计数段
	.i_diag_sof   (S_st_frames[7:0]),
	// 2026-10-21: JPEG 状态回读 (jpeg_regfile 0xA0 帧字节数 / 0xA8 STATUS)
	.i_jpeg_bytes (S_jpeg_st_bytes),
	.i_jpeg_busy  (S_jpeg_st_busy ),
	.i_jpeg_done  (S_jpeg_st_done ),
	.i_dbg_jpeg   (S_dbg_jpeg     ),
	.i_dbg_jb     (S_dbg_jb       ),
	// ★ V51: 移除 NV16 —— o_jpeg_tx / o_jpeg_dt18 不再使用 (MIPI 恒定发 JPEG,
	//   DT 恒定 0x18), 只留 0x0B[2] JPAD 作为帧长策略开关。
	.o_jpeg_tx    (               ),
	.o_jpeg_dt18  (               ),
	.o_jpeg_pad   (S_jpeg_pad     ),
	.i_diag_wbuf  (S_st_l_starve[7:0]),   // V53c: 原 D_wb_s2 -> 左路掉线恢复次数
	.i_diag_vs    (S_st_frames[15:8]),    // V53c: 原 D_vs_s2 -> 成帧数中字节
	.i_diag_lg1   (S_diag_bridge),   // V52b: 原 cam1 行组数诊断 -> 桥排水诊断
	.i_diag_tlast (S_diag_misc),     // V53c: 原 D_tl_s2 -> 桥 w_ready/源侧有效
	.i_diag_rxck  (S_diag_e1),       // V53c: 原 D_rxck_s2 -> 引擎1 o_diag[7:0]
	.i_diag_c1ck  (S_st_r_starve[7:0]),   // V53c: 原 D_c1ck_s2 -> 右路掉线恢复次数
	.i_diag_rtv   (S_diag_e2),       // V53c: 原 D_rtv_s2 -> 引擎2 o_diag[7:0]
	// ★ V53c: 这两个端口原来**根本没接**, 正好用来读拼接器的数据完整性告警
	//   0xDC = 左路补零/丢弃次数低 8 位
	//   0xD4/D5 = 已输出行数低 8 位 / 右路补零/丢弃次数低 8 位
	//   ⚠ st_* 在 S_hs_rx_clk (70MHz), 这里被 25MHz 寄存器采样, 多 bit CDC 会有
	//     脏快照 —— 但这几个都是慢变计数器, 看趋势/是否为 0 是可靠的。
	.i_dbg_status   (S_st_l_ovf[7:0]),
	.i_st_line_groups ({S_st_r_ovf[7:0], S_st_lines[7:0]}),
	// 2026-10-28 诊断: JPEG 编码器内部状态 (0xEA~0xEE)
	//   V48: 4 引擎 -> 只接首段(引擎0)和末段(引擎3), 便于对比
	.i_diag_enc_l (S_diag_enc[0]),
	.i_diag_enc_r (S_diag_enc[3]),
	.i_diag_enc_t (S_diag_enc_t),
	.i_diag_jv    (S_diag_jv),
	.i_fs_corr    (S_axis_tuser),        // 裁剪模块输出帧首
	.i_last_corr  (S_axis_tlast),        // 裁剪模块输出行尾
	// 2026-10-20: LP-free RX 调试总线 (只读 0xD6/0xD7/0xD8) = 固定 cam0
	// 2026-10-21: cam1 的独立一套 -> 0xDD/0xDE/0xDF; 两路打包 -> 0xDC
	.i_dbg_mipi      (S_rx_dbg_mipi),
	.i_dbg_delay     (S_rx_dbg_delay),
	.i_dbg_best_len  (S_rx_dbg_best_len),
	.i_dbg_autodone  (S_rx_autodone),
	.i_dbg1_mipi     (S_rx1_dbg_mipi),
	.i_dbg1_delay    (S_rx1_dbg_delay),
	.i_dbg1_best_len (S_rx1_dbg_best_len),
	.i_dbg1_autodone (S_rx1_autodone),
	.o_dbg_btn       (S_dbg_btn),
	.o_bayer_sel     (S_bayer_sel),
	// 2026-10-21: 0xDB CSI 源选择 (0=cam0 1=cam1)
	.o_rx_sel        (S_rx_sel),
	// 2026-10-21 双目交替
	.o_dual_en       (S_dual_en),
	.o_mark_en       (S_mark_en),
	.o_dual_start    (S_dual_start),
	.o_pp_mode    (S_pp_mode),
	.o_pp_sobel_gain (S_pp_sobel_sh),
	.o_pp_thresh  (S_pp_thresh),
	.o_pp_morph_sel (S_pp_morph_sel),
	.o_pp_morph_th  (S_pp_morph_th),
	.o_pp_lap_gain (S_pp_lap_sh),
	.o_pp_prew_gain(S_pp_prew_sh),
	.o_pp_emboss_gain(S_pp_emboss_gain),
	.o_pp_emboss_bias(S_pp_emboss_bias),
	.o_basic_en      (S_basic_en),
	.o_basic_gray    (S_basic_gray),
	.o_basic_gauss   (S_basic_gauss),
	.o_basic_ker     (S_basic_ker),
	.o_basic_he      (S_basic_he),
	.o_basic_he_clip (S_basic_he_clip),
	.o_basic_linefix (S_basic_linefix),
	.o_basic_contrast(S_basic_contrast),
	.o_cam_exp    (S_cam_exp),
	.o_cam_gain   (S_cam_gain),
	.o_cam_ev     (S_cam_ev),
	.o_cam_trig   (S_cam_trig),
	.i_cam_wr_cnt (S_cam_wr_cnt),
	.i_cam_busy   (S_cam_busy),
	.i_line_groups(S_line_groups),
	.o_wb_r       (S_wb_r),
	.o_wb_b       (S_wb_b),
	.o_roi_pct    (S_roi_pct),
	.o_fps_div    (S_fps_div),
	.o_res_mode   (S_res_mode),     // V21
	.o_res_chg    (S_res_chg)      // V21
);


//=============================================================================
//  诊断 (只读 0xE1~0xE3): 画面冻结定位 (2026-10-21)
//
//  背景: 现象是 fps 正常、帧标记正常, 但 RK 读到的永远是 DDR 里同一帧。
//  uidbuf 写状态机 
//      S_IDLE: if (I_W_en & wfifo_rst_done_r2 & w_fs) begin
//                  W_MS <= S_RST; ... O_W_sync_cnt 递增 ...
//  没有 w_fs(=tuser) 就永远停在 IDLE, 三帧缓存不轮转。
//  这三个计数器一次上板就能定位断在哪一环:
//     0xE1 涨、0xE2 不变 -> tuser 有, 但写缓冲不轮转 (读侧/防覆盖卡住)
//     0xE1 不变          -> sof 根本没进 dbuf (tuser 丢在更上游)
//     0xE3 不变          -> VTC 没跑, 读侧不启动(连带写侧卡住)
//=============================================================================
//  (声明已上移到文件前部的 S_R_vrst 之后, 这里只放 always 块)
//=============================================================================
always @(posedge S_hs_rx_clk or negedge S_pll_lock) begin
	if (!S_pll_lock)     D_sof_cnt <= 8'd0;
	else if (S_yuv_sof)  D_sof_cnt <= D_sof_cnt + 8'd1;
end
always @(posedge S_pclkx1 or negedge S_pll_lock) begin
	if (!S_pll_lock)     D_vs_cnt <= 8'd0;
	else if (S_vtc_vs)   D_vs_cnt <= D_vs_cnt + 8'd1;
end

// tlast 计数: 确认行尾有没有真的传下去(行宽不够 481 组时 tlast 永不出)
always @(posedge S_hs_rx_clk or negedge S_pll_lock) begin
	if (!S_pll_lock)              D_tl_cnt <= 8'd0;
	else if (S_axis_tlast)        D_tl_cnt <= D_tl_cnt + 8'd1;
end

// 时钟活性 + 数据到达 (0xE7/0xE8/0xE9)
always @(posedge S_hs_rx_clk)  D_rxck_cnt <= D_rxck_cnt + 8'd1;   // 自由跑
always @(posedge S_hs_clk1)    D_c1ck_cnt <= D_c1ck_cnt  + 8'd1;  // 自由跑
always @(posedge S_hs_rx_clk or negedge S_pll_lock) begin
	if (!S_pll_lock)              D_rtv_cnt <= 8'd0;
	else if (S_rx1_tvalid)        D_rtv_cnt <= D_rtv_cnt + 8'd1;
end

// 跨到 25MHz 域 (只读快照; 8bit 二进制同步, 变化很慢, 撕裂概率可忽略)
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) begin
		D_sof_s1 <= 8'd0; D_sof_s2 <= 8'd0;
		D_vs_s1  <= 8'd0; D_vs_s2  <= 8'd0;
		D_wb_s1  <= 8'd0; D_wb_s2  <= 8'd0;
		D_tl_s1  <= 8'd0; D_tl_s2  <= 8'd0;
		D_rxck_s1<= 8'd0; D_rxck_s2<= 8'd0;
		D_c1ck_s1<= 8'd0; D_c1ck_s2<= 8'd0;
		D_rtv_s1 <= 8'd0; D_rtv_s2 <= 8'd0;
		D_lg1_s1 <= 16'd0; D_lg1_s2 <= 16'd0;
	end else begin
		D_sof_s1 <= D_sof_cnt;   D_sof_s2 <= D_sof_s1;
		D_vs_s1  <= D_vs_cnt;    D_vs_s2  <= D_vs_s1;
		D_wb_s1  <= S_wbuf_sync; D_wb_s2  <= D_wb_s1;
		D_tl_s1  <= D_tl_cnt;    D_tl_s2  <= D_tl_s1;
		D_rxck_s1<= D_rxck_cnt;  D_rxck_s2<= D_rxck_s1;
		D_c1ck_s1<= D_c1ck_cnt;  D_c1ck_s2<= D_c1ck_s1;
		D_rtv_s1 <= D_rtv_cnt;   D_rtv_s2 <= D_rtv_s1;
		D_lg1_s1 <= S_line_groups1; D_lg1_s2 <= D_lg1_s1;
	end
end

//设置3帧缓存，读延迟写1帧
ui_setvbuf#(
	.BUF_DELAY		(1			),
	.BUF_LENTH		(3			)
)
X_ui_setvbuf
(
	.I_bufn			(S_wbuf_sync),
	.O_bufn			(S_rbuf_sync)
);


//例化uidbuf 控制器
// ★ 2026-10-28 V51: 移除 NV16 —— dbuf 读侧只服务 JPEG 编码器
//   tready 直接交给 yuv32_to_quad 的 FIFO: 编码器慢就撑住当前帧,
//   写侧继续用另外两帧 -> 丢整帧不丢行。
//   (原来 NV16 那条 S_vtc_de_valid & S_dsi_pack_tready 已随打包器一起删掉)
wire        S_ud_rtready = S_jcfg_r_ready;

ui_dbuf# (  
	.AXI_DATA_WIDTH	(AXI_DATA_WIDTH		),//AXI总线数据位宽
	.AXI_ADDR_WIDTH	(AXI_ADDR_WIDTH		),//AXI总线地址位宽
	.ENABLE_VSYNC	(1					),
	.W_BUFDEPTH		(2048				),//写通道AXI设置FIFO缓存大小
	.W_DATAWIDTH	(64					),//V21: YUV422×4 = 16bpp×4 = 64b (pre-DDR RGB→YUV 后)
	.W_BASEADDR		(0					),//写通道设置内存起始地址
	.W_DSIZEBITS	(25					),//写通道设置缓存数据的增量地址大小，用于FDMA DBUF 计算帧缓存起始地址
	.W_XDIV			(2					),//写通道对X方向数据拆分为XDIV次传输，减少FIFO的使用
	.W_BUFSIZE		(3					),//写通道设置帧缓存大小，目前最大支持128帧，可以修改参数支持更缓存数
		
	.R_BUFDEPTH		(2048				),//读通道AXI设置FIFO缓存大小
	.R_DATAWIDTH	(32					),//V21: 32b/cyc = 2 像素 YUV422 (YUYV pair)
	.R_BASEADDR		(0					),//读通道设置内存起始地址
	.R_DSIZEBITS	(25					),//读通道设置缓存数据的增量地址大小，用于FDMA DBUF 计算帧缓存起始地址
	.R_XDIV			(2					),//读通道对X方向数据拆分为XDIV次传输，减少FIFO的使用
	.R_BUFSIZE		(3					) //读通道设置帧缓存大小，目前最大支持128帧，可以修改参数支持更缓存数
)
X_ui_dbuf
(
	.I_ui_clk		(S_dfi_clk			),
	.I_ui_rstn		(S_ud_rstn			),   // V30: 原为 S_ddr_init_cal_done -> 模式切换永不复位
	// ==== V21: 运行时尺寸 (帧内保持稳定) ====
	.I_W_XSIZE		(S_w_beats			),
	.I_W_XSTRIDE	(S_w_beats			),
	.I_W_YSIZE		(S_v_active			),
	.I_R_XSIZE		(S_r_beats			),
	.I_R_XSTRIDE	(S_r_beats			),
	.I_R_YSIZE		(S_v_active			),
		
	.I_W_en      	(1					),
	.I_W_wclk    	(S_ud_wclk			),
	.I_W_tuser   	(S_ud_wtuser		),
	.I_W_tvalid  	(S_ud_wtvalid		),
	.I_W_tdata   	(S_ud_wtdata		),
	.I_W_tlast   	(S_ud_wtlast		),
	.O_W_tready  	(					),
	.O_W_sync_cnt	(S_wbuf_sync		),
	.I_W_buf     	(S_wbuf_sync		),
	
	.I_R_en      	(S_vtc_vs			),
	.I_R_rclk    	(S_pclkx1			),
	.I_R_tready  	(S_ud_rtready),
	.O_R_tuser   	(S_dsi_R_tuser		),
	.O_R_tvalid  	(S_dsi_R_tvalid		),
	.O_R_tdata   	(S_ud_rtdata		),
	.O_R_tlast   	(S_dsi_R_tlast		),
	.O_R_sync_cnt	(					),
	.I_R_buf     	(S_rbuf_sync		),
	.O_R_vrst    	(S_R_vrst			),
	
	.O_fdma_waddr 	(S_fdma_waddr		),
	.O_fdma_wareq 	(S_fdma_wareq		),
	.O_fdma_wsize 	(S_fdma_wsize		),
	.I_fdma_wbusy 	(S_fdma_wbusy		),
	.O_fdma_wdata 	(S_fdma_wdata		),
	.I_fdma_wvalid	(S_fdma_wvalid		),
	.O_fdma_wready	(S_fdma_wready		),
	.O_fdma_raddr 	(S_fdma_raddr		),
	.O_fdma_rareq 	(S_fdma_rareq		),
	.O_fdma_rsize 	(S_fdma_rsize		),
	.I_fdma_rbusy 	(S_fdma_rbusy		),
	.I_fdma_rdata 	(S_fdma_rdata		),
	.I_fdma_rvalid	(S_fdma_rvalid		),
	.O_fdma_rready	(S_fdma_rready		)
	//.O_fmda_wbuf  	(fdma_wbuf			),	
	//.O_fdma_wirq  	(fdma_wirq			),		
	//.O_fmda_rbuf  	(fdma_rbuf			),	
	//.O_fdma_rirq  	(fdma_rirq			)
);

//例化米联客uiFDMA AXI 控制器 IP
ui_FDMA#
(
	.M_AXI_B2B_SET		(1				),
	.M_AXI_ID_WIDTH		(AXI_ID_WIDTH	),//ID位宽
	.M_AXI_ADDR_WIDTH	(AXI_ADDR_WIDTH	),//内存地址位宽
	.M_AXI_DATA_WIDTH	(AXI_DATA_WIDTH	),//AXI总线的数据位宽
	.M_AXI_MAX_BURST_LEN(16				) //AXI总线的burst 大小，对于AXI4，支持任意长度，对于AXI3以下最大16
)
X_ui_FDMA
(
	.I_fdma_waddr		(S_fdma_waddr	),//FDMA写通道地址
	.I_fdma_wareq		(S_fdma_wareq	),//FDMA写通道请求
	.I_fdma_wsize		(S_fdma_wsize	),//FDMA写通道一次FDMA的传输大小                                            
	.O_fdma_wbusy		(S_fdma_wbusy	),//FDMA处于BUSY状态，AXI总线正在写操作  
					
	.I_fdma_wdata		(S_fdma_wdata	),//FDMA写数据
	.O_fdma_wvalid		(S_fdma_wvalid	),//FDMA 写有效
	.I_fdma_wready		(1'b1			),//FDMA写准备好，用户可以写数据
	
	.I_fdma_raddr		(S_fdma_raddr	),// FDMA读通道地址
	.I_fdma_rareq		(S_fdma_rareq	),// FDMA读通道请求
	.I_fdma_rsize		(S_fdma_rsize	),// FDMA读通道一次FDMA的传输大小                                      
	.O_fdma_rbusy		(S_fdma_rbusy	),// FDMA处于BUSY状态，AXI总线正在读操作 
					
	.O_fdma_rdata		(S_fdma_rdata	),// FDMA读数据
	.O_fdma_rvalid		(S_fdma_rvalid	),// FDMA 读有效
	.I_fdma_rready		(1'b1			),// FDMA读准备好，用户可以读数据

//以下为AXI总线信号		
	.M_AXI_ACLK         (S_dfi_clk		),
	.M_AXI_ARESETN      (S_ud_rstn),
// Master Interface Write Address Ports
	.M_AXI_AWID         (S_axi_awid		),
	.M_AXI_AWADDR       (S_axi_awaddr	),
	.M_AXI_AWLEN        (S_axi_awlen	),
	.M_AXI_AWSIZE       (S_axi_awsize	),
	.M_AXI_AWBURST      (S_axi_awburst	),
	.M_AXI_AWLOCK       (				),
	.M_AXI_AWCACHE      (S_axi_awcache	),
	.M_AXI_AWPROT       (S_axi_awprot	),
	.M_AXI_AWQOS        (				),
	.M_AXI_AWVALID      (S_axi_awvalid	),
	.M_AXI_AWREADY      (S_axi_awready	),
// Master Interface Write Data Ports
	.M_AXI_WDATA        (S_axi_wdata	),
	.M_AXI_WSTRB        (S_axi_wstrb	),
	.M_AXI_WLAST        (S_axi_wlast	),
	.M_AXI_WVALID       (S_axi_wvalid	),
	.M_AXI_WREADY       (S_axi_wready	),
// Master Interface Write Response Ports
	.M_AXI_BID          (S_axi_bid		),
	.M_AXI_BRESP        (S_axi_bresp	),
	.M_AXI_BVALID       (S_axi_bvalid	),
	.M_AXI_BREADY       (S_axi_bready	),
// Master Interface Read Address Ports
	.M_AXI_ARID         (S_axi_arid		),
	.M_AXI_ARADDR       (S_axi_araddr	),
	.M_AXI_ARLEN        (S_axi_arlen	),
	.M_AXI_ARSIZE       (S_axi_arsize	),
	.M_AXI_ARBURST      (S_axi_arburst	),
	.M_AXI_ARLOCK       (				),
	.M_AXI_ARCACHE      (S_axi_arcache	),
	.M_AXI_ARPROT       (				),
	.M_AXI_ARQOS        (				),
	.M_AXI_ARVALID      (S_axi_arvalid	),
	.M_AXI_ARREADY      (S_axi_arready	),
// Master Interface Read Data Ports
	.M_AXI_RID          (S_axi_rid		),
	.M_AXI_RDATA        (S_axi_rdata	),
	.M_AXI_RRESP        (S_axi_rresp	),
	.M_AXI_RLAST        (S_axi_rlast	),
	.M_AXI_RVALID       (S_axi_rvalid	),
	.M_AXI_RREADY       (S_axi_rready	)		
);


//例化DDR IP
//===== DDR3 PHY INS =====//
ui_ddr X_ui_ddr (

	.sys_rst_n  		(S_pll_lock		),
    .sys_clk    		(I_ddr_clk		),

// DDRIO
`ifdef MC0_DRAM_DDR4
    .ddr_ck_t       	(				),
    .ddr_ck_c       	(				),
    .ddr_reset_n    	(				),
    .ddr_cke        	(				),
    .ddr_odt        	(				),
    .ddr_cs_n       	(				),
    .ddr_act_n      	(				),
    .ddr_bg         	(				),
    .ddr_ba         	(				),
    .ddr_addr       	(				),
    .ddr_dqs_t      	(				),
    .ddr_dqs_c      	(				),
    .ddr_dq         	(				),
    .ddr_dm_dbi     	(				),
`else
    .ddr_ck_p       	(ddr_ck_p		),    
    .ddr_ck_n       	(ddr_ck_n		),    
    .ddr_reset_n    	(ddr_reset_n	),   
    .ddr_cke        	(ddr_cke		),   
    .ddr_odt        	(ddr_odt		),    
    .ddr_cs_n       	(ddr_cs_n		),     
    .ddr_ras_n      	(ddr_ras_n		),    
    .ddr_cas_n      	(ddr_cas_n		), 		
    .ddr_we_n       	(ddr_we_n		),     
    .ddr_ba         	(ddr_ba			), 
    .ddr_addr       	(ddr_addr		),        
    .ddr_dqs_p      	(ddr_dqs_p		),   
    .ddr_dqs_n      	(ddr_dqs_n		),   
    .ddr_dq         	(ddr_dq			),
    .ddr_dm            	(ddr_dm			),
`endif

    .ctl_ram_rst_n     	(				),
    .ctl_ram_cke       	(				),

// user interface ports
    .dfi_clk           	(S_dfi_clk		),
    .pll_locked        	(				),
    .ddrphy_rst_n      	(				),
    .ddr_init_cal_done 	(S_ddr_init_cal_done),
    .ddr_init_cal_err  	(				),
    .ddr_init_cal_step 	(				),

// mc user interface
`ifdef MC0_MIS_AXI
// AXI Interface
    .axi_aclk          	(				),
    .axi_aresetn       	(				),
// AXI Write Address Channel
    .axi_awid          (S_axi_awid   	),
    .axi_awaddr        (S_axi_awaddr 	),
    .axi_awlen         (S_axi_awlen  	),
    .axi_awsize        (S_axi_awsize 	),
    .axi_awburst       (S_axi_awburst	),
    .axi_awlock        (S_axi_awlock 	),
    .axi_awcache       (S_axi_awcache	),
    .axi_awprot        (S_axi_awprot 	),
    .axi_awqos         (S_axi_awqos  	),
    .axi_awvalid       (S_axi_awvalid	),
    .axi_awready       (S_axi_awready	),
// AXI Write Data Channel
    .axi_wdata         (S_axi_wdata 	),
    .axi_wstrb         (S_axi_wstrb 	),
    .axi_wlast         (S_axi_wlast 	),
    .axi_wvalid        (S_axi_wvalid	),
    .axi_wready        (S_axi_wready	),
// AXI Write Response Channel
    .axi_bid           (S_axi_bid   	),
    .axi_bresp         (S_axi_bresp 	),
    .axi_bvalid        (S_axi_bvalid	),
    .axi_bready        (S_axi_bready	),
// AXI Read Address Channel
    .axi_arid          (S_axi_arid   	),
    .axi_araddr        (S_axi_araddr 	),
    .axi_arlen         (S_axi_arlen  	),
    .axi_arsize        (S_axi_arsize 	),
    .axi_arburst       (S_axi_arburst	),
    .axi_arlock        (S_axi_arlock 	),
    .axi_arcache       (S_axi_arcache	),
    .axi_arprot        (S_axi_arprot 	),
    .axi_arqos         (S_axi_arqos  	),
    .axi_arvalid       (S_axi_arvalid	),
    .axi_arready       (S_axi_arready	),
// AXI Read Data Channel
    .axi_rid           (S_axi_rid   	),
    .axi_rdata         (S_axi_rdata 	),
    .axi_rresp         (S_axi_rresp 	),
    .axi_rlast         (S_axi_rlast 	),
    .axi_rvalid        (S_axi_rvalid	),
    .axi_rready        (S_axi_rready	),
`else  // PAXI
// Write Address Ports
    .paxi_awaddr       (				), 
    .paxi_awvalid      (				), 
    .paxi_awready      (				), 
// Write Data Ports    				
    .paxi_wdata        (				), 
    .paxi_wstrb        (				), 
    .paxi_wvalid       (				), 
    .paxi_wlast        (				), 
    .paxi_wready       (				), 
// Write Response Port 				
    .paxi_bresp        (				), 
    .paxi_bvalid       (				), 
    .paxi_bready       (				), 
// Read Address Ports  				
    .paxi_araddr       (				), 
    .paxi_arvalid      (				), 
    .paxi_arready      (				), 			 
// Read Data Ports     				
    .paxi_rdata        (				), 
    .paxi_rlast        (				), 
    .paxi_rvalid       (				), 
    .paxi_rready       (				), 
`endif
// PZQ Share
    .pzq_cal_done_i    (				),
    .pzq_cal_done_o    (				),
// DFX				
    .user_clk          (				), 
    .apb_clk           (				), 
    .mcu_busy          (				), 
    .user_update       (				), 
    .user_ram_addr     (				), 
    .user_ram_wr_en    (				), 
    .user_ram_rd_en    (				), 
    .user_ram_wr_data  (				), 
    .user_ram_rd_data  (				), 
				
    .uart_rxd          (				),
    .uart_txd          (				)
);

//=============================================================================
//  V23 (2026-10-16): 复位窗已上移到文件前部
//  生成逻辑见 "V23 ... 整条视频通路协同复位" 一节 (在写侧第一个使用点之前)。
//  这里只把**读侧** (S_pclkx1 域) 的复位取出来。
//  ⚠ 不要再把计数逻辑搬回这个位置 —— 写侧 (ui_csi_unpacket / ui_raw10 /
//    ui_image_correction / ui_isp_top / preproc_*) 在文件更早的地方就要用到
//    复位信号, 放在这里会被 Verilog 隐式声明成 1bit wire。
//=============================================================================
assign S_res_rstn = ~S_res_win_pclk[1];

ui_vtc X_ui_vtc (
	.I_H_ActiveSize    (S_vtc_h_active						), //视频时间参数,行视频信号，一行有效(需要显示的部分)像素所占的时钟数，一个时钟对应一个有效像素
	.I_H_SyncStart      (S_vtc_h_start					), //视频时间参数,行同步开始，即多少时钟数后开始产生行同步信号 
	.I_H_SyncEnd        (S_vtc_h_end				), //视频时间参数,行同步结束，即多少时钟数后停止产生行同步信号，之后就是行有效数据部分
	.I_H_FrameSize      (S_vtc_h_frame			), //视频时间参数,行视频信号，一行视频信号总计占用的时钟数
	
	.I_V_ActiveSize    (S_vtc_v_active						), //视频时间参数,场视频信号，一帧图像所占用的有效(需要显示的部分)行数量，通常说的视频分辨率即H_ActiveSize*V_ActiveSize
	.I_V_SyncStart      (S_vtc_v_start					), //视频时间参数,场同步开始，即多少行数后开始产生场同步信号 
	.I_V_SyncEnd        (S_vtc_v_end				), //视频时间参数,场同步结束，多少行后停止产生长同步信号  
	.I_V_FrameSize      (S_vtc_v_frame			), //视频时间参数,场视频信号，一帧视频信号总计占用的行数量        
    .I_vtc_rstn		   (~S_R_vrst & S_res_rstn		), //系统复位
    .I_vtc_clk		   (S_pclkx1		), //系统时钟
    .O_vtc_vs		   (S_vtc_vs		), //场同步输出
    .O_vtc_hs		   (S_vtc_hs		), //行同步输出
    .O_vtc_de_valid	   (S_vtc_de_valid	), //视频数据有效	
    .O_vtc_user		   (S_vtc_user		), //满足stream时序产生 user 信号,用于帧同步
    .O_vtc_last        (S_vtc_last      )  //满足stream时序产生 later 信号,用于每行结束
);



//---- DSI 专用 PLL (25MHz 输入 -> 25/150/300/600/600@90/10MHz) ----
//  V21: VCO 从 1000MHz 提到 1200MHz; byte_clk(clk1) 125->150MHz,
//       lane 速率 = 8 x byte_clk = 1200 Mbps (改前 1000) => 4lane 600MB/s
pll_dsi u_ui_pll_dsi (
	.refclk		(I_sysclk_25m		),
	.reset		(1'b0				),
	.lock		(S_dsi_pll_lock		),
	.clk0_out	(S_dsi_25m_unused	),	// 25MHz feedback (BUFG)
	.clk1_out	(S_dsi_byte_clk		),	// 75MHz
	.clk2_out	(S_dsi_hs_x2		),	// 150MHz
	.clk3_out	(S_dsi_hs_x4		),	// 300MHz
	.clk4_out	(S_dsi_hs_x4_90d	),	// 300MHz @90°
	.clk5_out	(S_dsi_lp_clk		)	// 10MHz LP init
);

//---- I_dsi_en 同步 (sys_clk 25MHz 域) ----
always @(posedge I_sysclk_25m) begin
	S_dsi_en_sync <= {S_dsi_en_sync[0], I_dsi_en};
end

//=============================================================================
//  ★ 2026-10-28 V51: 移除 NV16 —— 下面整段 (读侧帧标记注入 + YUV422 打包器)
//  全部删除。
//
//  这些代码的用途是给 NV16 通路做"上板可见性"验证: 往 NV16 的 Y 平面里
//  塞 A5 5A src FF, 让网页能确认"数据是 FPGA 发的、不是 RK 缓存的旧帧"。
//  NV16 通路已经不存在, 而且这几个标记字节对 JPEG 码流是纯粹的污染。
//
//  历史留档 (别再踩):
//    写侧 (S_mark_en && S_yuv_sof) 的做法实测完全没生效 —— S_yuv_sof 在本机
//    基本不来, 因为 uidbuf 的 wfifo_rst_done 只要上电见过一次 I_W_tuser 就
//    永久锁存, 之后没有 tuser 也照常写 DDR, 画面一直是好的, 极隐蔽。
//    读侧的 O_R_tuser 才可靠 (dbuf 读状态机自己按"读地址回 0"产生)。
//=============================================================================


//=============================================================================
//  ★ 2026-10-28 V51: 移除 NV16 —— 内置测试图案源 (csi2_test_src) 一并删除
//
//  它是 NV16 通路的链路自测工具: TPG -> csi2_frame_tx(定长, DT=0x1E) -> D-PHY,
//  用来二分"CRC 到底出在 TX 还是上游"。现在定长 TX 已经不存在, TPG 也就
//  无处可去 (它输出 32bit YUV422 word, 而 csi2_frame_tx_var 吃 8bit 字节流,
//  硬接还得再加一级字节化)。
//
//  历史结论留档 (V50b 实测, 别重复做):
//    切到 TPG 后 fps 稳定 50.4, frame_id 5 秒涨 252, MIPI_CSI2 错误 0,
//    IOMMU page fault 0 => "FPGA->MIPI->RK" 这一段本身是干净的,
//    当时的 CRC 全在 csi2_pack_yuv422_stream 的整行预取丢失上。
//  ⚠ 50.4 fps 就是 3840 宽 NV16 在这个 byte_clk 下的物理上限, 不是故障。
//
//  csi2_test_src.v 文件保留在工程里 (不例化就不参与综合), 以后要压链路
//  可以给它加一层 32->8 字节化再接到 X_jv 上。
//=============================================================================


//=============================================================================
//  ★ 2026-10-28 V51: 移除 NV16 —— 定长 CSI-2 组包器 (csi2_frame_tx) 删除
//
//  它就是 NV16 的组包器: 每行一个定长长包 (DT=0x1E, 1920 word),
//  GAP_LINE=200 / GAP_FRAME=4000。JPEG 走的是变长组包器 csi2_frame_tx_var
//  (X_jv, 在本文件更早的位置), 所以这里整块不再需要。
//
//  连同它一起删掉的还有 TX_SRC_SEL 三选一 mux 和 S_hs_en/S_hs_data/S_hs_last。
//
//  历史留档 (这条链路的 GAP 已经被调死, 别在新通路上照抄):
//    GAP_LINE=200 (1.6us) 是实测验证过的: 4K25 下 rkcif 25.00fps, ECC=0, CRC=0。
//    V38f 改成 100 想"增加每行余量", 结果 4K 掉到 0.99fps 并爆 e2/crc;
//    GAP_LINE=40 在 V38b 也试过, 同样报 CRC/ECC。
//    原因: 减小 GAP 是把 TX 对上游的吞吐要求提高了, 并不会给出任何余量;
//    而且定长 TX 在 payload 期间只要 s_tvalid 掉一拍就会把 hs_en 拉低,
//    那等于把这个 packet 提前截断 -> 必然报错。
//=============================================================================

//---- Layer-1 只有 JPEG 变长组包 X_jv (见本文件 "CSI-2 可变长发送" 一节) ----

//---- Layer-0: Anlogic D-PHY TX wrapper (LP init + HS 串化) ----
mipi_dphy_tx_wrapper #(
	.LANE_NUM				(4      ),
	.HS_TX_FIFO_TYPE		("DRAM" ),
	.LP_TX_FIFO_TYPE		("DRAM" ),
	.LP_TX_MAX_DATA_LENGTH	(8      ),
	.CLK_LANE_MODE			("INTERRUPT"),
	.T_DATA_LPX				(10	),
	.T_DATA_HS_PREPARE		(7	),
	.T_DATA_HS_ZERO			(30	),
	.T_DATA_HS_TRAIL		(20	),
	.T_CLK_LPX				(10	),
	.T_CLK_PREPARE			(10	),
	.T_CLK_ZERO				(10	),
	.T_CLK_PRE				(10	),
	.T_CLK_POST				(10	),
	.T_CLK_TRAIL			(10	)
) u_dphy_tx (
	.I_hs_clk		(S_dsi_byte_clk			),
	.I_hs_clk_x2	(S_dsi_hs_x2			),
	.I_hs_clk_x4	(S_dsi_hs_x4			),
	.I_hs_clk_x4_90d(S_dsi_hs_x4_90d		),
	.I_lpdt_clk		(S_dsi_lp_clk			),
	.I_rst			(~S_dphy_rst_n			),

	// HS TX: ★ V51 移除 NV16 后只有 JPEG 变长组包这一路, 不再有 mux
	.I_hs_tx_valid	(S_jv_hs_en				),
	.I_hs_tx_data	(S_jv_hs_data			),
	.I_hs_tx_last	(S_jv_hs_last			),
	.O_hs_tx_ready	(						),

	// LP TX: 不发 LP 配置 (CSI-2 host 不需)
	.I_lp_tx_valid	(1'b0					),
	.I_lp_tx_data	(8'h00					),
	.I_lp_tx_last	(1'b0					),
	.O_lp_tx_ready	(						),

	// pad
	.O_clk_hs_p		(O_mipi_dsi_hs_clk_p	),
	.O_data_hs_p	(O_mipi_dsi_hs_data_p	),
	.O_clk_lp_p		(O_mipi_dsi_lp_clk_p	),
	.O_clk_lp_n		(O_mipi_dsi_lp_clk_n	),
	.O_data_lp_p	(O_mipi_dsi_lp_data_p	),
	.O_data_lp_n	(O_mipi_dsi_lp_data_n	)
);

endmodule
