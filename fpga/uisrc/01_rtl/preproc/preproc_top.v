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

	// ---- 视频输入 ----
	input  wire         i_tvalid,
	input  wire         i_tuser,
	input  wire         i_tlast,
	input  wire [127:0] i_rgb,

	// ---- 配置 (来自 jpeg_regfile 的 0xB0 段) ----
	input  wire [2:0]   i_mode,          // 0=原图 1=Sobel 2=阈值 3=形态学
	input  wire [3:0]   i_sobel_shift,
	input  wire [7:0]   i_thresh,
	input  wire         i_morph_sel,

	// ---- 视频输出 ----
	output wire         o_tvalid,
	output wire         o_tuser,
	output wire         o_tlast,
	output wire [127:0] o_rgb
);

	wire         w_tvalid, w_tuser, w_tlast;
	wire [2:0]   w_rowmask;
	wire [47:0]  w_winA, w_winB, w_winC;
	wire [127:0] w_rgb;

	preproc_win3x3 #(
		.PX_PER_CLK (PX_PER_CLK)
	) u_win (
		.clk       (clk),
		.rst_n     (rst_n),
		.I_nw      (i_h_active >> 2),   // V21: 每行字数 = 宽度/4
		.i_tvalid  (i_tvalid),
		.i_tuser   (i_tuser),
		.i_tlast   (i_tlast),
		.i_rgb     (i_rgb),
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
		.o_tvalid       (o_tvalid),
		.o_tuser        (o_tuser),
		.o_tlast        (o_tlast),
		.o_rgb          (o_rgb)
	);

endmodule
