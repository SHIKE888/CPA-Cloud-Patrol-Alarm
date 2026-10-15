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
--     -> MIPI CSI-2 RX (4 lane)          : mipi_dphy_rx_over_lvds_wrapper
--     -> CSI-2 解包 + RAW10 还原          : ui_csi_unpacket_4lane / ui_raw10_unpacket_4lane
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
	input  wire		    			I_clk_hs_p  ,	
	input  wire	[3:0]				I_data_hs_p , 
	input  wire	[3:0]				I_data_lp_p ,
	input  wire	[3:0]				I_data_lp_n ,
	
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

wire          					S_hs_rx_clk		;  
wire          					S_hs_rx_valid	;  
wire [31 : 0] 					S_hs_rx_data	; 
wire [3 : 0]					S_lane_error	;

wire        					S_csi_frame_start;       
wire        					S_csi_frame_end	;         
wire        					S_csi_valid		;             
wire[31:0]  					S_csi_data		;  
	
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


rgb_to_yuv422_quad u_rgb2yuv_quad (
	.clk        (S_hs_rx_clk    ),
	.rst_n      (S_pll_lock     ),
	.i_de       (S_pp_tvalid    ),   // 改接预处理输出 (原 S_ISP_O_tvalid)
	.i_user_sof (S_pp_tuser     ),
	.i_last     (S_pp_tlast     ),
	.i_data     (S_pp_tdata     ),
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

//手动配置相机AE
ui_ae_set X_ui_ae_set (
	.I_clk			(S_clk_24m		),
	.I_rst			(S_pll_lock		),
	.I_btn			(2'b11			),
	.I_cam_cfg_done	(S_cam_cfg_done	),
	.I_ae_cfg_done	(S_ae_cfg_done	),
	.O_ae_req		(S_ae_req		),
	.O_ae			(S_ae			)
  );
  
//IIC协议配置摄像头寄存器
ui_cfg_imx415#(
	.CLK_DIV(24_000_000/100_000-1)
	)
X_ui_cfg_imx415(
	.I_clk			(S_clk_24m		),  
	.I_rst_n		(S_pll_lock		),  
	.I_ae_req		(S_ae_req		),
	.I_ae_data		(S_ae			),
	.O_cam_scl		(O_cam_scl		), 
	.IO_cam_sda		(IO_cam_sda		), 
	.O_cfg_done		(S_cam_cfg_done	),
	.O_ae_cfg_done	(S_ae_cfg_done	)
  );

//mipi_rx
mipi_dphy_rx_over_lvds_wrapper#(
    .DEVICE           ( "PH1"		 ),
    .LANE_NUM         ( 4    		 )
)X_mipi_dphy_rx_over_lvds_wrapper(
    .I_lp_clk         ( S_clk_70m    ),
    .I_rst            ( ~S_pll_lock  ),

    .I_mipi_clk_p     ( I_clk_hs_p   ),
    .I_mipi_data_hs_p ( I_data_hs_p  ),
    .I_mipi_data_lp_p ( I_data_lp_p  ),
    .I_mipi_data_lp_n ( I_data_lp_n  ),

    .I_lane_hs_invert ( 4'b0000      ),
    .I_lane_lp_invert ( 4'b0000      ),

    .O_hs_rx_clk      ( S_hs_rx_clk  ),
    .O_hs_rx_valid    ( S_hs_rx_valid),
    .O_hs_rx_data     ( S_hs_rx_data ),

    .O_lp_rx_lane0_p  (				 ),
    .O_lp_rx_lane0_n  (				 ),

    .O_lane_error     ( S_lane_error )
);

//csi解码模块
ui_csi_unpacket_4lane X_ui_csi_unpacket_4lane(
	.I_clk            ( S_hs_rx_clk       ),
	.I_rst_n          ( S_pll_lock        ),
	.I_hs_valid       ( S_hs_rx_valid     ),
	.I_hs_data        ( S_hs_rx_data      ),
		
	.O_csi_frame_start( S_csi_frame_start ),
	.O_csi_frame_end  ( S_csi_frame_end   ),
	.O_csi_valid      ( S_csi_valid       ),
	.O_csi_data       ( S_csi_data        )
);

//转为RAW10数据格式
ui_raw10_unpacket_4lane X_ui_raw10_unpacket_4lane (
	.I_clk  			(S_hs_rx_clk		),
	.I_rst_n			(S_pll_lock			),
		
	.I_csi_frame_start	(S_csi_frame_start	),
	.I_csi_frame_end  	(S_csi_frame_end	),
	.I_csi_valid      	(S_csi_valid		),
	.I_csi_data       	(S_csi_data			),
		
	.O_raw10_frame_start(S_raw10_frame_start),
	.O_raw10_frame_end  (S_raw10_frame_end  ),
	.O_raw10_valid      (S_raw10_valid      ),
	.O_raw10_data       (S_raw10_data       )
);

//图像大小裁剪模块
ui_image_correction #(
    .DATA_WIDTH  (40),
    .TDEST_WIDTH (10)
)X_ui_image_correction
(
    .I_clk            (S_hs_rx_clk		  ),
    .I_rst_n          (S_pll_lock		  ),
	
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
	.I_rst_n         (S_pll_lock		),
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
wire         S_pp_tvalid;
wire         S_pp_tuser;
wire         S_pp_tlast;
wire [127:0] S_pp_tdata;
wire [2:0]   S_pp_mode;
wire [3:0]   S_pp_sobel_sh;
wire [7:0]   S_pp_thresh;
wire         S_pp_morph_sel;

preproc_top #(
	.H_ACTIVE   (H_ACTIVE),
	.PX_PER_CLK (4)
) u_preproc (
	.clk            (S_hs_rx_clk),
	.rst_n          (S_pll_lock),
	.i_tvalid       (S_ISP_O_tvalid),
	.i_tuser        (S_ISP_O_tuser),
	.i_tlast        (S_ISP_O_tlast),
	.i_rgb          (S_ISP_O_tdata),
	.i_mode         (S_pp_mode),
	.i_sobel_shift  (S_pp_sobel_sh),
	.i_thresh       (S_pp_thresh),
	.i_morph_sel    (S_pp_morph_sel),
	.o_tvalid       (S_pp_tvalid),
	.o_tuser        (S_pp_tuser),
	.o_tlast        (S_pp_tlast),
	.o_rgb          (S_pp_tdata)
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
	.CFG_VER  (16'h0101)
) u_cfg_ctrl (
	.i_sys_clk    (I_sysclk_25m),
	.i_sys_rst_n  (1'b1),
	.i_scl        (S_cfg_scl_i),
	.i_sda        (S_cfg_sda_i),
	.o_sda_drive  (S_cfg_sda_drv),
	.i_pix_clk    (S_hs_rx_clk),
	.i_pix_rst_n  (S_pll_lock),
	.i_frame_tuser(S_ISP_O_tuser),
	.o_pp_mode    (S_pp_mode),
	.o_pp_sobel_shift (S_pp_sobel_sh),
	.o_pp_thresh  (S_pp_thresh),
	.o_pp_morph_sel (S_pp_morph_sel)
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
	.W_XSIZE		(W_BEATS_PER_LINE	),//写通道设置X方向的数据大小，代表了每次FDMA 传输的数据长度 (64bit/beat = 4px YUV422)
	.W_XSTRIDE		(W_BEATS_PER_LINE	),//写通道设置X方向的Stride值，主要用于图形缓存应用
	.W_YSIZE		(V_ACTIVE			),//写通道设置Y方向值，代表了进行了多少次XSIZE传输
	.W_XDIV			(2					),//写通道对X方向数据拆分为XDIV次传输，减少FIFO的使用
	.W_BUFSIZE		(3					),//写通道设置帧缓存大小，目前最大支持128帧，可以修改参数支持更缓存数
		
	.R_BUFDEPTH		(2048				),//读通道AXI设置FIFO缓存大小
	.R_DATAWIDTH	(32					),//V21: 32b/cyc = 2 像素 YUV422 (YUYV pair)
	.R_BASEADDR		(0					),//读通道设置内存起始地址
	.R_DSIZEBITS	(25					),//读通道设置缓存数据的增量地址大小，用于FDMA DBUF 计算帧缓存起始地址
	.R_XSIZE		(R_BEATS_PER_LINE	),//读通道: 32bit/beat = 2 像素 YUV422 -> H_ACTIVE/2 beat/行
	.R_XSTRIDE		(R_BEATS_PER_LINE	),//读通道: 同上
	.R_YSIZE		(V_ACTIVE			),//读通道设置Y方向值，代表了进行了多少次XSIZE传输
	.R_XDIV			(2					),//读通道对X方向数据拆分为XDIV次传输，减少FIFO的使用
	.R_BUFSIZE		(3					) //读通道设置帧缓存大小，目前最大支持128帧，可以修改参数支持更缓存数
)
X_ui_dbuf
(
	.I_ui_clk		(S_dfi_clk			),
	.I_ui_rstn		(S_ddr_init_cal_done),
		
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
	.M_AXI_ARESETN      (S_ddr_init_cal_done),
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

ui_vtc #(
	.H_ActiveSize      (H_ACTIVE						), //视频时间参数,行视频信号，一行有效(需要显示的部分)像素所占的时钟数，一个时钟对应一个有效像素
	.H_SyncStart       (H_ACTIVE+H_FP					), //视频时间参数,行同步开始，即多少时钟数后开始产生行同步信号 
	.H_SyncEnd         (H_ACTIVE+H_FP+H_SA				), //视频时间参数,行同步结束，即多少时钟数后停止产生行同步信号，之后就是行有效数据部分
	.H_FrameSize       (H_ACTIVE+H_FP+H_SA+H_BP			), //视频时间参数,行视频信号，一行视频信号总计占用的时钟数
	
	.V_ActiveSize      (V_ACTIVE						), //视频时间参数,场视频信号，一帧图像所占用的有效(需要显示的部分)行数量，通常说的视频分辨率即H_ActiveSize*V_ActiveSize
	.V_SyncStart       (V_ACTIVE+V_FP					), //视频时间参数,场同步开始，即多少行数后开始产生场同步信号 
	.V_SyncEnd         (V_ACTIVE+V_FP+V_SA				), //视频时间参数,场同步结束，多少行后停止产生长同步信号  
	.V_FrameSize       (V_ACTIVE+V_FP+V_SA+V_BP			)  //视频时间参数,场视频信号，一帧视频信号总计占用的行数量        
) 
X_ui_vtc
(
    .I_vtc_rstn		   (~S_R_vrst		), //系统复位
    .I_vtc_clk		   (S_pclkx1		), //系统时钟
    .O_vtc_vs		   (S_vtc_vs		), //场同步输出
    .O_vtc_hs		   (S_vtc_hs		), //行同步输出
    .O_vtc_de_valid	   (S_vtc_de_valid	), //视频数据有效	
    .O_vtc_user		   (S_vtc_user		), //满足stream时序产生 user 信号,用于帧同步
    .O_vtc_last        (S_vtc_last      )  //满足stream时序产生 later 信号,用于每行结束
);



//---- DSI 专用 PLL (25MHz 输入 -> 25/75/150/300/300@90/10MHz) ----
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

csi2_pack_yuv422_stream #(
	.H_ACTIVE	(H_ACTIVE),
	.V_ACTIVE	(V_ACTIVE)
) u_csi2_pack (
	// source: ui_dbuf.R (S_pclkx1 域)
	.src_clk		(S_pclkx1			),
	.src_rst_n		(S_pll_lock			),
	.s_tvalid		(S_dsi_R_tvalid		),
	.s_tready		(S_dsi_pack_tready	),
	.s_tdata		(S_dsi_R_tdata32	),
	.s_tuser_sof	(S_dsi_R_tuser		),
	.s_tlast		(S_dsi_R_tlast		),
	// sink: byte_clk 域 YUV422 AXIS
	.dst_clk		(S_dsi_byte_clk		),
	.dst_rst_n		(S_dphy_rst_n		),
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
//=============================================================================
localparam JPEG_TEST_SRC = 1'b0;

wire        S_test_tvalid;
wire [31:0] S_test_tdata;
wire        S_test_tsof;
wire        S_test_tlast;

csi2_test_src #(
	.H_ACTIVE	(H_ACTIVE),
	.V_ACTIVE	(V_ACTIVE),
	.BPP_NUM	(2),
	.BPP_DEN	(1),
	.MODE		(0),            // 0 = 线性计数 (逐字节可校验)
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

// 数据源二选一 (常量选择, 综合时只保留一路)
wire        S_tx_tvalid = JPEG_TEST_SRC ? S_test_tvalid : S_pack_tvalid;
wire [31:0] S_tx_tdata  = JPEG_TEST_SRC ? S_test_tdata  : S_pack_tdata;
wire        S_tx_tsof   = JPEG_TEST_SRC ? S_test_tsof   : S_pack_tsof;
wire        S_tx_tlast  = JPEG_TEST_SRC ? S_test_tlast  : S_pack_tlast;

csi2_frame_tx #(
	.DT			(6'h1E),	// YUV422-8bit  (必须与 RK 驱动 MEDIA_BUS_FMT_YUYV8_2X8 一致)
	.VC			(2'd0 ),
	.H_ACTIVE	(H_ACTIVE ),
	.V_ACTIVE	(V_ACTIVE ),
	.BPP_NUM	(2    ),
	.BPP_DEN	(1    ),
	.GAP_LINE	(32'd200 ),
	.GAP_FRAME	(32'd4000)
) u_csi2_frame_tx (
	.clk			(S_dsi_byte_clk	),
	.rst_n			(S_dphy_rst_n	),
	.enable			(S_dsi_en_int	),
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

