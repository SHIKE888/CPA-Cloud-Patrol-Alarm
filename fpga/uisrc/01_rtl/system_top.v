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
--     -> YUV422 跨时钟域打包              : csi2_pack_yuv422_stream
--     -> CSI-2 帧/包组包 (DT=0x1E)        : csi2_frame_tx
--     -> D-PHY TX (4 lane HS + LP)        : mipi_dphy_tx_wrapper
--     -> RK3576 CSI3 (csi2_dphy3 / mipi3_csi2)
--     -> RK 端 milianke_mipi 驱动 -> CIF/ISP -> VPSS
--     -> HDMI 2.1 输出 1080P60 画面
--
-- 关键点:
--   1) 输出格式固定 YUV422-8bit (DT=0x1E), 分辨率 1920x1080@60,
--      必须与 RK 端驱动 milianke_mipi.c 中上报的
--      MEDIA_BUS_FMT_YUYV8_2X8 / 1920x1080 / 4 lane 完全一致。
--   2) I_dsi_en 由 RK 侧 (dts 里 mipi-en-gpios = gpio1 RK_PD0) 驱动,
--      高电平才使能 D-PHY 发送; 驱动的 s_stream() 打开流时置高。
--   3) 无摄像头自检: 见同目录 system_top_tx_tpg.v + fpga_pin_tx_tpg.adc,
--      用内部测试图案替代 IMX415, 可用于先验证 FPGA->RK->HDMI 通路。
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

	//摄像头配置信号
	output wire 					O_clk_24m	,	//摄像头工作时钟
	output wire 					O_clk_rst	,	//摄像头复位信号,默认上拉
    output wire 					O_cam_scl	,   //I2C总线，SCL时钟
    inout  wire 					IO_cam_sda	,   //I2C总线，SDA数据
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
	wire        S_res_chg;                           // 模式写入脉冲 (25MHz 域)
	wire        S_res_rstn;                          // 模式切换复位窗 (S_pclkx1 域)
	wire [15:0] S_line_groups;                       // V21 诊断: 每行像素组数

	// 4K 模式 (2'd1/@30 与 2'd2/@25) 的图像尺寸完全相同, 只有 VTC 场周期不同
	wire        S_is_4k        = (S_res_mode != 2'd0);

	// ---- 图像宽高 ----
	wire [12:0] S_h_active     = S_is_4k ? 13'd3840 : H_ACTIVE[12:0];
	wire [11:0] S_v_active     = S_is_4k ? 12'd2160 : V_ACTIVE[11:0];
	wire [15:0] S_w_beats      = S_is_4k ? 16'd960  : 16'd480;
	wire [15:0] S_r_beats      = S_is_4k ? 16'd1920 : 16'd960;
	// V39: 传感器垂直裁剪起点。4K 录制区从第 36 行开始 (厂商 v_start=35)；
	//      1080p 厂商参考 v_start=19。首行必须是偶数，否则 RGGB Bayer 相位错。
	wire [12:0] S_v_start      = S_is_4k ? 13'd35  : 13'd19;

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
	// 4K 场周期: 与 h_frame=2652 配套 -> 147.5MHz/(2652 x 2225) = 24.997fps
	wire [11:0] S_vtc_v_frame  = (S_res_mode == 2'd2) ? 12'd2225
	                           : (S_res_mode == 2'd1) ? 12'd2387
	                                                  : (V_ACTIVE+V_FP+V_SA+V_BP);
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
	wire							S_dsi_byte_clk	;	// 75MHz  -> wrapper I_hs_clk
	wire							S_dsi_hs_x2		;	// 150MHz -> wrapper I_hs_clk_x2
	wire							S_dsi_hs_x4		;	// 300MHz -> wrapper I_hs_clk_x4
	wire							S_dsi_hs_x4_90d	;	// 300MHz @90 -> wrapper I_hs_clk_x4_90d
	wire							S_dsi_lp_clk	;	// 10MHz  -> wrapper I_lpdt_clk
	wire							S_dsi_pll_lock	;

	//---- ui_dbuf R-side AXIS hookups for DSI chain ----
	wire							S_dsi_R_tuser	;
	wire							S_dsi_R_tvalid	;
	wire							S_dsi_R_tlast	;
	wire	[31:0]					S_dsi_R_tdata32	;	// RGBX8888 (1 像素/cyc) 出 dbuf.R
	wire							S_dsi_pack_tready;

	//---- DSI 握手同步 + 复位 ----
	reg  [1:0]						S_dsi_en_sync	= 2'b00;
	wire							S_dsi_en_int	= S_dsi_en_sync[1];
	wire							S_dphy_rst_n	= S_pll_lock & S_dsi_pll_lock & S_dsi_en_int;

wire [7:0]						S_ae			;
wire 							S_cam_cfg_done	;
wire 							S_ae_cfg_done	;
wire 							S_ae_req		;

wire          					S_hs_rx_clk		;   // 新 RX 的 byte clock (= HS clk / 4)

	//---- LP-free CSI-2 RX (03_ip/mipi_csi_lpfree) 的 AXIS 输出 ----
	wire							S_rx_rstn		;
	wire [39:0]						S_rx_tdata		;
	wire							S_rx_tvalid		;
	wire							S_rx_tlast		;
	wire							S_rx_tuser		;

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
					
assign O_clk_rst				= 1'b1;
	
assign S_ud_wclk 				= S_hs_rx_clk	;
assign S_ud_wtuser 				= S_yuv_sof		;
assign S_ud_wtvalid 			= S_yuv_de		;
assign S_ud_wtlast 				= S_yuv_last	;
assign S_ud_wtdata 				= S_yuv_data	;


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
wire [4:0]   S_pp_sharp_gain;
wire [4:0]   S_basic_en;
wire         S_basic_gray;
wire [3:0]   S_basic_gauss;
wire [1:0]   S_basic_ker;
wire [7:0]   S_basic_he;
wire [7:0]   S_basic_he_clip;
wire [3:0]   S_basic_he_temp;
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

rgb_to_yuv422_quad u_rgb2yuv_quad (
	.clk        (S_hs_rx_clk    ),
	.rst_n      (S_pll_lock     ),
	.i_de       (S_post_tvalid  ),   // 后级输出 (白平衡 + ROI)
	.i_user_sof (S_post_tuser   ),
	.i_last     (S_post_tlast   ),
	.i_data     (S_post_tdata   ),
	.o_de       (S_yuv_de       ),
	.o_user_sof (S_yuv_sof      ),
	.o_last     (S_yuv_last     ),
	.o_data     (S_yuv_data     )
);


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
	.I_rst_n		(S_pll_lock		),  
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
// 写侧(含 ISP/预处理)一起复位。若万一某版 ISP 的复位恢复时间不可接受,
// 把这一个常量置 0 即可退回"只复位读侧"的旧行为, 不用改别的地方。
localparam        RES_RST_TX_SIDE = 1'b1;

reg  [1:0]  S_res_chg_d;
reg  [23:0] S_res_hold25;
always @(posedge I_sysclk_25m or negedge S_pll_lock) begin
	if (!S_pll_lock) begin
		S_res_chg_d  <= 2'b00;
		S_res_hold25 <= 24'd0;
	end else begin
		S_res_chg_d <= {S_res_chg_d[0], S_res_chg};
		if (S_res_chg_d == 2'b01)          S_res_hold25 <= RES_RST_CYCLES;
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
always @(posedge S_dsi_byte_clk or negedge S_pll_lock) begin
	if (!S_pll_lock) S_res_win_byte <= 2'b00;
	else             S_res_win_byte <= {S_res_win_byte[0], S_res_win25};
end

wire S_res_rstn_rx   = RES_RST_TX_SIDE ? ~S_res_win_rx[1]   : 1'b1;
wire S_res_rstn_byte = ~S_res_win_byte[1];

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
	else if (S_res_chg_d == 2'b01)       S_ud_dly <= 18'd1;        // 从切换沿开始计时
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
//   1) I_debug_button 必须接 1'b1。07 工程里它是"上拉按键未按下"的电平;
//      接 0 会在复位后产生一次 11->01 的边沿, 把 RX 锁进 manual delay 模式,
//      自动 eye-scan 就不再执行了。
//   2) m_axis_video_tready 恒 1。该 AXIS 的 tvalid = tready & ~empty,
//      下游没有反压 (和原来的 raw10 通路一致)。
//   3) 参考时钟用 I_ddr_clk (T13, 100MHz LVDS)。07 工程用 PLL 出 150MHz,
//      但 ref clock 只被 csi_rx_clock_det 用来计时 (判断 HS 时钟还在不在),
//      100MHz 只影响"判丢时钟"的时间常数, 不影响采样与 eye-scan。
//=============================================================================
// ⚠ 复位只能依赖 25MHz 域的 S_pll_lock / S_dphy_rx_rst。
//   绝不能把 S_res_rstn_rx (它是 S_hs_rx_clk 域里 2 级同步出来的寄存器)
//   接进来: S_hs_rx_clk 就是 RX 自己分频出来的, RX 被复位 -> 没时钟 ->
//   那个同步器永远不更新 -> 复位永远不放 -> 死锁。
assign S_rx_rstn = S_pll_lock & ~S_dphy_rx_rst;

mipi_csi_rx #(
	.MIPI_LAN        ( 4      ),
	.DEVICE          ( "PH1A" )
)X_mipi_csi_rx(
	.I_debug_button        ( 1'b1        ),
	.I_ref_clock           ( I_ddr_clk   ),
	.I_clk_hs_rx_p         ( I_clk_hs_p  ),
	.I_reset_n             ( S_rx_rstn   ),
	.I_hs_data_p           ( I_data_hs_p ),
	.I_enable              ( 1'b1        ),

	.O_hs_div_clk          ( S_hs_rx_clk ),

	.m_axis_video_aclk     ( S_hs_rx_clk   ),
	.m_axis_video_aresetn  ( S_rx_rstn     ),
	.m_axis_video_tready   ( 1'b1          ),
	.m_axis_video_tuser    ( S_rx_tuser    ),
	.m_axis_video_tlast    ( S_rx_tlast    ),
	.m_axis_video_tvalid   ( S_rx_tvalid   ),
	.m_axis_video_tdata    ( S_rx_tdata    ),

	// 调试总线 -> I2C 只读寄存器 0xD6/0xD7/0xD8
	.O_auto_delay_done     ( S_rx_autodone     ),
	.O_dbg_mipi            ( S_rx_dbg_mipi     ),
	.O_dbg_delay           ( S_rx_dbg_delay    ),
	.O_dbg_best_len        ( S_rx_dbg_best_len )
);

// AXIS(40bit RAW10, tuser=帧首) -> ui_image_correction 的 raw10 接口
assign S_raw10_valid       = S_rx_tvalid;
assign S_raw10_data        = S_rx_tdata;
assign S_raw10_frame_start = S_rx_tvalid & S_rx_tuser;
assign S_raw10_frame_end   = 1'b0;                        // 该模块不使用
assign S_csi_frame_start   = S_rx_tvalid & S_rx_tuser;    // 供 cfg_ctrl_top 统计真实帧率


//图像大小裁剪模块
ui_image_correction #(
    .DATA_WIDTH  (40),
    .TDEST_WIDTH (10)
)X_ui_image_correction
(
    .O_line_groups    (S_line_groups     ),  // V21 诊断: 每行像素组数
    .I_clk            (S_hs_rx_clk		  ),
    // V23: 裁剪边界跟 S_h_active/S_v_active 走, 模式一切换就必须复位重对齐
    .I_rst_n          (S_pll_lock & S_res_rstn_rx		  ),
    // V21: 运行时宽高
    .I_img_width      (S_h_active		  ),
    .I_img_height     (S_v_active		  ),
    // V39: 垂直起始裁剪 (4K=35, 1080p=19)
    .I_v_start        (S_v_start		  ),
	
    .I_raw_data       (S_raw10_data       ),       
    .I_raw_valid      (S_raw10_valid      ),     
    .I_raw_frame_start(S_raw10_frame_start),
    .I_raw_frame_end  (S_raw10_frame_end  ),
    
    .O_raw_tdata 	  (S_axis_tdata 	  ),
    .O_raw_tlast 	  (S_axis_tlast 	  ),
    .O_raw_tvalid	  (S_axis_tvalid	  ),
    .O_raw_tuser 	  (S_axis_tuser 	  )

);



//米联客ISP图像处理模块
ui_isp_top X_ui_isp_top (
	.I_clk		     (S_hs_rx_clk		),
	// V23: ISP 内部也有按宽高走的行/列计数器, 一起复位
	.I_rst_n         (S_pll_lock & S_res_rstn_rx		),
	.I_img_width     (S_h_active		),
	.I_img_height    (S_v_active		),
	.I_is_4k         (S_is_4k			),  // V40: 4K=RGGB, 1080p binning=GRBG
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
	.i_he_temp      (S_basic_he_temp),
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
	.i_sharp_gain   (S_pp_sharp_gain),
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
	.DEV_ADDR (7'h40),
	// ★ 构建版本号 (I2C 0xA9 低 / 0xAA 高 可读)。注意这里会覆盖 cfg_ctrl_top
	//   的 parameter 默认值 —— 2026-10-17 就因为改错地方导致版本号一直读 0x0101,
	//   白白多烧了一轮。以后改这个号只能改这里。
	//   0x3807 = V38g (撤销 V38f: GAP_LINE 100->200, 回到实测可用的 4K25)
	//   0x3805 = V38e (4K25: h_frame 2652 / v_frame 2225 / VMAX 3420)
	//   0x3804 = V38d (补上 0x3024/0x3025: VMAX 3449->4282)
	//   0x4301 = V43a (修 4K 撕裂: packer 写侧幻影 word + 读侧重复送)
	//           ⚠ 注意: 4:36 那次构建虽然已经是 V43 的 RTL, 但当时这里还是
	//           0x3807, 所以板上读到的仍是 0x3807 —— 不能只凭版本号判断是否
	//           烧了新 bit, 要看画面/相位相关。
	//   0x4509 = 2026-10-20 修 IDELAY 使能语义(电平) + eye-scan 只扫 32 tap
	.CFG_VER  (16'h4509)
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
	.i_fs_corr    (S_axis_tuser),        // 裁剪模块输出帧首
	.i_last_corr  (S_axis_tlast),        // 裁剪模块输出行尾
	// 2026-10-20: LP-free RX 调试总线 (只读 0xD6/0xD7/0xD8)
	.i_dbg_mipi      (S_rx_dbg_mipi),
	.i_dbg_delay     (S_rx_dbg_delay),
	.i_dbg_best_len  (S_rx_dbg_best_len),
	.i_dbg_autodone  (S_rx_autodone),
	.o_pp_mode    (S_pp_mode),
	.o_pp_sobel_gain (S_pp_sobel_sh),
	.o_pp_thresh  (S_pp_thresh),
	.o_pp_morph_sel (S_pp_morph_sel),
	.o_pp_morph_th  (S_pp_morph_th),
	.o_pp_lap_gain (S_pp_lap_sh),
	.o_pp_prew_gain(S_pp_prew_sh),
	.o_pp_emboss_gain(S_pp_emboss_gain),
	.o_pp_emboss_bias(S_pp_emboss_bias),
	.o_pp_sharp_gain (S_pp_sharp_gain),
	.o_basic_en      (S_basic_en),
	.o_basic_gray    (S_basic_gray),
	.o_basic_gauss   (S_basic_gauss),
	.o_basic_ker     (S_basic_ker),
	.o_basic_he      (S_basic_he),
	.o_basic_he_clip (S_basic_he_clip),
	.o_basic_he_temp (S_basic_he_temp),
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
	.I_R_tready  	(S_vtc_de_valid & S_dsi_pack_tready),
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

assign S_dsi_R_tdata32 = S_ud_rtdata;

//---- Layer-2: RGB32 -> YUV422 跨时钟域打包 ----
wire        S_pack_tvalid;
wire        S_pack_tready;
wire [31:0] S_pack_tdata;
wire        S_pack_tsof;
wire        S_pack_tlast;

csi2_pack_yuv422_stream u_csi2_pack (
	// V21: 运行时尺寸
	.I_h_active		(S_h_active			),
	.I_v_active		(S_v_active			),
	// source: ui_dbuf.R (S_pclkx1 域)
	.src_clk		(S_pclkx1			),
	// V22: 模式切换复位窗也要给打包器 —— 否则它的字节计数/行状态机
	// 会跟新的行/帧边界错位而卡死(实测只复位 VTC 时 TX 彻底不出帧)
	.src_rst_n		(S_pll_lock & S_res_rstn),
	.s_tvalid		(S_dsi_R_tvalid		),
	.s_tready		(S_dsi_pack_tready	),
	.s_tdata		(S_dsi_R_tdata32	),
	.s_tuser_sof	(S_dsi_R_tuser		),
	.s_tlast		(S_dsi_R_tlast		),
	// sink: byte_clk 域 YUV422 AXIS
	.dst_clk		(S_dsi_byte_clk		),
	// V23: 用 byte_clk 域自己同步出来的复位 (原来借用 S_pclkx1 域的, 跨域不干净)
	.dst_rst_n		(S_dphy_rst_n & S_res_rstn_byte),
	.enable			(S_dsi_en_int		),
	.m_tvalid		(S_pack_tvalid		),
	.m_tready		(S_pack_tready		),
	.m_tdata		(S_pack_tdata		),
	.m_tuser_sof	(S_pack_tsof		),
	.m_tlast		(S_pack_tlast		)
);

//=============================================================================
//  传输链路自测源 (JPEG_TEST_SRC = 1 时启用)
//
//  发"逐字节可校验"的线性递增序列, 用来在 JPEG 编码器写出来之前, 先把
//  "FPGA -> MIPI x4 -> RK -> 用户态"这条链路验掉 —— 这是目前风险最高的环节。
//  RK 端抓一帧后逐字节比对 (帧内第 k 字节 == k & 0xFF), 只要全对就证明
//  CSI-2 传输是比特精确的 (没有丢字节/重复/错位)。
//  帧结构与现有 YUV422 通路完全一致 (1920x1080, 2 字节/像素), RK 侧不用改。
//
//  测完把 JPEG_TEST_SRC 置回 0 即可恢复正式通路; 它是常量, 综合时
//  没用到的那一路会被直接优化掉, 不占资源。
//
//  2026-10-15: 链路验证已通过 (3 帧 12,441,600 字节 零误差), 置 0 恢复正式通路。
//
//  ★ 2026-10-17 V32: 置 1 做【单 4K MIPI 纯传输 demo】
//    目的: 把 "4K 撕裂" 到底出在 TX/CSI-2/RK 这一段, 还是出在 RX/ISP/DDR/packer
//    这一段彻底分开。打开后整条输出通路变成:
//        内置 4K 测试图案 -> csi2_frame_tx -> D-PHY TX -> RK
//    完全绕开 IMX415 RX / ui_isp / preproc / ui_dbuf / csi2_pack。
//    配合 V31 (FPGA 上电即 4K25), 默认就是 3840x2160 的 checker 图案。
//    图案 = 64x64 模盘 + 每 64 行/列的亮网格线 + 行号斜坡 (全灰度,
//    不受 YUYV 字节序影响), 重得/镜像/上下绕回一眼可见。
//    测完把本常量置回 1'b0 即恢复正式通路。
//=============================================================================
localparam JPEG_TEST_SRC = 1'b0;   // V33: 内置 TPG 关(下面 TX_SRC_SEL 直接选源)

// ★ V33 (2026-10-17) TX 数据源三选一 —— 二分定位 4K 撕裂的上游归属
//   已确定(V32 demo, 用户亲眼确认): 内置4K棋盘 -> frame_tx -> D-PHY -> RK 干净满帧,
//     绿紫相间(与我算的 YUYV 解释一致) => TX/CSI-2/D-PHY/rkcif 接收段正常
//   已排除: ui_image_correction (4K 下 h_cnt 1..960=3840px, 966->960 裁剪正确)
//   已排除: 链路速率档 / 模式切换 / rkcif 不支持 3840 宽
//   本参数把 csi2_frame_tx 的输入在三个点之间切:
//     2'd0 = csi2_pack 输出      (正式通路)
//     2'd1 = ui_dbuf.R 直连, 跳过 csi2_pack  <-- 本次隔离测试
//     2'd2 = 内置 TPG            (已证明干净的基准)
//   ui_dbuf 的读输出本身就是 32bit YUV422 word, O_R_tuser/O_R_tlast 与
//   packer 的 m_tuser_sof/m_tlast 语义一致(帧首/行尾), 可以直连。
//   判定: 直连后画面干净 => 元凶是 csi2_pack (4K 一行 1920 word, A-FIFO 仅 2048)
//         仍撕裂          => 在 ui_dbuf / ui_isp / preproc / RX解包, 继续前二分
// V33a: 2'd1 (dbuf 直连) 实测失败 —— ui_dbuf 的读输出在 S_pclkx1 域,
//        而 csi2_frame_tx 在 S_dsi_byte_clk 域, csi2_pack 本来就在兼做 CDC。
//        直接跨域灌进去的结果是 "csi size err, size 0x0" (一个包都没有)。
//        => 这个 tap 点不成立, 改回正式通路。要测 csi2_pack 必须穿透一个 CDC。
localparam [1:0] TX_SRC_SEL = 2'd0;

wire        S_test_tvalid;
wire [31:0] S_test_tdata;
wire        S_test_tsof;
wire        S_test_tlast;

csi2_test_src #(
	.H_ACTIVE	(3840),         // V32: 4K demo (必须是常呈, 与 V31 的 RES_MODE=2 一致)
	.V_ACTIVE	(2160),
	.BPP_NUM	(2),
	.BPP_DEN	(1),
	.MODE		(2),            // V32: 2 = 4K 几何诊断图案(模盘+网格+行号斜坡)
	.LFSR_SEED	(32'hDEAD_BEEF)
) u_csi2_test_src (
	.clk			(S_dsi_byte_clk		),
	.rst_n			(S_dphy_rst_n		),
	.enable			(S_dsi_en_int & JPEG_TEST_SRC),
	.m_tvalid		(S_test_tvalid		),
	.m_tready		(S_pack_tready		),
	.m_tdata		(S_test_tdata		),
	.m_tuser_sof	(S_test_tsof		),
	.m_tlast		(S_test_tlast		)
);

//---- Layer-1: CSI-2 帧 FSM (DT=0x1E YUV422-8bit) ----
wire        S_hs_en;
wire [31:0] S_hs_data;
wire        S_hs_last;

// 数据源三选一 (常量选择, 综合时只保留一路)
//   TX_SRC_SEL: 0=packer 正式通路  1=ui_dbuf.R 直连(跳过packer)  2=内置TPG
wire        S_tx_tvalid = (TX_SRC_SEL == 2'd2) ? S_test_tvalid :
                          (TX_SRC_SEL == 2'd1) ? S_dsi_R_tvalid : S_pack_tvalid;
wire [31:0] S_tx_tdata  = (TX_SRC_SEL == 2'd2) ? S_test_tdata  :
                          (TX_SRC_SEL == 2'd1) ? S_dsi_R_tdata32: S_pack_tdata;
wire        S_tx_tsof   = (TX_SRC_SEL == 2'd2) ? S_test_tsof   :
                          (TX_SRC_SEL == 2'd1) ? S_dsi_R_tuser  : S_pack_tsof;
wire        S_tx_tlast  = (TX_SRC_SEL == 2'd2) ? S_test_tlast  :
                          (TX_SRC_SEL == 2'd1) ? S_dsi_R_tlast  : S_pack_tlast;

csi2_frame_tx #(
	.DT			(6'h1E),	// YUV422-8bit  (必须与 RK 驱动 MEDIA_BUS_FMT_YUYV8_2X8 一致)
	.VC			(2'd0 ),
	.BPP_NUM	(2    ),
	.BPP_DEN	(1    ),
	// ★★★ 不要动这两个参数 ★★★
	//   GAP_LINE=200 (1.6us) 是实测验证过的: 4K25 下 rkcif 25.00 fps, ECC=0, CRC=0。
	//   V38f 曾把它改成 100 想"增加每行余量", 结果 4K 直接掉到 0.99 fps,
	//   并爆出 MIPI_CSI2 ERR1:0x10000000 (ecc2) / ERR1:0x18000000 (crc,vc:3)。
	//   原因: 减小 GAP 是把 TX 对上游 packer 的吞吐要求提高了(每行 16.98us->16.18us),
	//         并不会给出任何余量; 而且 csi2_frame_tx 在 payload 期间只要 s_tvalid 掉一拍
	//         就会把 hs_en 拉低, 那等于把这个 packet 提前截断 -> 必然报错。
	//   GAP_LINE=40 (320ns) 在 V38b 也试过, 同样报 CRC/ECC。
	//   => 这条链路的 GAP 已经调好了, 逐行偏移要另找原因。
	.GAP_LINE	(32'd200 ),
	.GAP_FRAME	(32'd4000)
) u_csi2_frame_tx (
	.clk			(S_dsi_byte_clk	),
	// V22: 同 csi2_pack —— 包/帧状态机必须在模式切换时一起复位,
	// 否则它与新的行/帧边界错位后会卡死(实测: RX 计数在涨但 TX 不出帧)
	.rst_n			(S_dphy_rst_n & S_res_rstn_byte),
	.enable			(S_dsi_en_int	),
	.I_h_active		(S_h_active		),
	.I_v_active		(S_v_active		),
	.s_tvalid		(S_tx_tvalid	),
	.s_tready		(S_pack_tready	),
	.s_tdata		(S_tx_tdata		),
	.s_tuser_sof	(S_tx_tsof		),
	.s_tlast		(S_tx_tlast		),
	.hs_en			(S_hs_en		),
	.hs_data		(S_hs_data		),
	.hs_last		(S_hs_last		),
	.frame_cnt		(				),
	.packet_cnt		(				)
);

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

	// HS TX from Layer-1
	.I_hs_tx_valid	(S_hs_en				),
	.I_hs_tx_data	(S_hs_data				),
	.I_hs_tx_last	(S_hs_last				),
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

