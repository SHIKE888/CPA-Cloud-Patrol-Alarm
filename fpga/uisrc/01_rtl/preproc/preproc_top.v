//=============================================================================
//  preproc_top.v
//  预处理流水线顶层: 3x3 亮度窗口 + Sobel / 阈值分割 / 形态学 三路并行
//
//  插入位置: ui_isp_top (RGB888x4, 128bit) 与 rgb_to_yuv422_quad 之间。
//  延迟: 约 3 拍 + 1 拍输出寄存 = 4 拍。下游按 AXI-Stream 消费, 不关心确定延迟。
//
//  ⚠ 本模块**不改变帧的行结构**: 输入 1080 行, 输出也是 1080 行 (帧首两行的
//    纵向邻域无效时用当前行顶替)。绝不能丢行, 否则下游色度平面会整体错位。
//=============================================================================
`timescale 1ns / 1ps

module preproc_top #(
	parameter integer PX_PER_CLK = 4
)(
	input  wire         clk,
	input  wire         rst_n,
	// V21: 运行时有效宽度 (行缓冲地址回绕用)
	input  wire [12:0]  i_h_active,
	// V45: 帧高 (直方图分帧用)
	input  wire [11:0]  i_v_active,

	// ---- 视频输入 ----
	input  wire         i_tvalid,
	input  wire         i_tuser,
	input  wire         i_tlast,
	input  wire [127:0] i_rgb,

	// ---- 初级预处理配置 (0xF0~0xF4, 多选位图) ----
	input  wire [4:0]   i_basic_en,      // bit0 灰度 bit1 高斯 bit2 HE bit3 对比度 bit4 反色
	input  wire         i_gray_mode,     // 0=BT.601 1=BT.709
	input  wire [3:0]   i_gauss_str,     // 0..8
	input  wire [7:0]   i_he_str,        // 0..255
	input  wire [3:0]   i_contrast,      // 0..8

	// ---- 高级预处理配置 (0xB1~0xB7, 0xF5~0xF7, 单选) ----
	input  wire [3:0]   i_mode,          // 0=关 1=Sobel 2=阈值 3=形态 4=中值 5=拉普拉斯 6=浮雕 7=Prewitt 8=锐化
	input  wire [3:0]   i_sobel_shift,
	input  wire [7:0]   i_thresh,
	input  wire         i_morph_sel,
	input  wire [7:0]   i_morph_th,
	input  wire [3:0]   i_lap_shift,
	input  wire [3:0]   i_prew_shift,
	input  wire [3:0]   i_emboss_gain,
	input  wire [7:0]   i_emboss_bias,
	input  wire [3:0]   i_sharp_gain,

	// ---- 视频输出 ----
	output wire         o_tvalid,
	output wire         o_tuser,
	output wire         o_tlast,
	output wire [127:0] o_rgb
);

	//--------------------------------------------------------------- 初级层
	wire         b_tvalid, b_tuser, b_tlast;
	wire [127:0] b_rgb;

	preproc_basic #(
		.PX_PER_CLK (PX_PER_CLK)
	) u_basic (
		.clk         (clk),
		.rst_n       (rst_n),
		.i_h_active  (i_h_active),
		.i_v_active  (i_v_active),
		.i_tvalid    (i_tvalid),
		.i_tuser     (i_tuser),
		.i_tlast     (i_tlast),
		.i_rgb       (i_rgb),
		.i_en        (i_basic_en),
		.i_gray_mode (i_gray_mode),
		.i_gauss_str (i_gauss_str),
		.i_he_str    (i_he_str),
		.i_contrast  (i_contrast),
		.o_tvalid    (b_tvalid),
		.o_tuser     (b_tuser),
		.o_tlast     (b_tlast),
		.o_rgb       (b_rgb)
	);

	//--------------------------------------------------------------- 高级层
	wire         w_tvalid, w_tuser, w_tlast;
	wire [2:0]   w_rowmask;
	wire [47:0]  w_winA, w_winB, w_winC;
	wire [127:0] w_rgb;

	preproc_win3x3 #(
		.PX_PER_CLK (PX_PER_CLK)
	) u_win (
		.clk       (clk),
		.rst_n     (rst_n),
		.I_nw      ({3'd0, (i_h_active >> 2)}),   // V21: 每行字数 = 宽度/4
		.i_tvalid  (b_tvalid),
		.i_tuser   (b_tuser),
		.i_tlast   (b_tlast),
		.i_rgb     (b_rgb),
		.o_tvalid  (w_tvalid),
		.o_tuser   (w_tuser),
		.o_tlast   (w_tlast),
		.o_rowmask (w_rowmask),
		.o_winA    (w_winA),
		.o_winB    (w_winB),
		.o_winC    (w_winC),
		.o_rgb     (w_rgb)
	);

	preproc_edge u_edge (
		.clk            (clk),
		.rst_n          (rst_n),
		.i_tvalid       (w_tvalid),
		.i_tuser        (w_tuser),
		.i_tlast        (w_tlast),
		.i_rowmask      (w_rowmask),
		.i_winA         (w_winA),
		.i_winB         (w_winB),
		.i_winC         (w_winC),
		.i_rgb          (w_rgb),
		.i_mode         (i_mode),
		.i_sobel_shift  (i_sobel_shift),
		.i_thresh       (i_thresh),
		.i_morph_sel    (i_morph_sel),
		.i_morph_th     (i_morph_th),
		.i_lap_shift    (i_lap_shift),
		.i_prew_shift   (i_prew_shift),
		.i_emboss_gain  (i_emboss_gain),
		.i_emboss_bias  (i_emboss_bias),
		.i_sharp_gain   (i_sharp_gain),
		.o_tvalid       (o_tvalid),
		.o_tuser        (o_tuser),
		.o_tlast        (o_tlast),
		.o_rgb          (o_rgb)
	);

endmodule
