`timescale 1ns/1ps
//==============================================================================
//  preproc_post.v —— 预处理后级: 数字白平衡 + ROI 裁剪
//
//  位置: preproc_top 之后, rgb_to_yuv422_quad 之前。
//  **不改变行/帧结构** (1080 行进, 1080 行出), 所以 RK 侧时序、驱动都不用动。
//
//  ── 数字白平衡 ──
//    对 R/B 通道各乘一个增益 (128 = 1.0x, 192 = 1.5x, 64 = 0.5x)。
//    IMX415 是 RAW sensor, 自身没有白平衡寄存器 —— 它的 AWB 是在 ISP 里做的,
//    而本工程用的 ui_awb 是**全自动**的、没有手动增益接口 (见 ui_awb.v 端口表)。
//    所以"手动白平衡"只能放在这一级做, 好处是随时可调、立即生效。
//      计算: out = (in * gain + 64) >> 7      (四舍五入)
//
//  ── ROI 裁剪 ──
//    中心裁剪 + 四周填黑, 等效于数字变焦。输出分辨率不变 (1920x1080), 只是
//    有效画面变小、外面是黑边。
//    为什么不真正改输出分辨率: ui_vtc 的 H_ActiveSize/H_FrameSize 等都是
//    编译期 #() 参数, 运行时改不了; 就算改了, RK 侧驱动上报的
//    1920x1080@60 也得同步改。
//    为什么不做缩放: 缩放要行缓冲 + 多相滤波器, 是另一个量级的工程。
//
//    ⚠ ROI 宽度用**移位/加减**算, 不用除法 —— 组合除法器在 148.5MHz 下很容易
//      时序不过。档位: 100% / 75% / 50% / 37.5% / 25% / 12.5%
//
//  黑边为什么填 RGB=0: 经 rgb_to_yuv422_quad 后有 +16 的视频范围偏移,
//  RGB(0,0,0) -> Y=16/U=V=128, 正是标准的"视频黑", 不会发灰。
//==============================================================================
module preproc_post #(
	parameter integer PX_PER_CLK = 4
)(
	input  wire         clk,
	input  wire         rst_n,

	// V21: 运行时图像尺寸 (原为编译期 H_ACTIVE/V_ACTIVE 参数)
	input  wire [11:0]  i_h_active,
	input  wire [11:0]  i_v_active,

	input  wire         i_tvalid,
	input  wire         i_tuser,
	input  wire         i_tlast,
	input  wire [127:0] i_rgb,

	input  wire [7:0]   i_wb_r,      // R 增益, 128 = 1.0x
	input  wire [7:0]   i_wb_b,      // B 增益, 128 = 1.0x
	input  wire         i_mono,      // 1 = 上游是单色算子(边缘/阈值/形态/中值/拉普拉斯/浮雕/Prewitt) -> 跳 WB
	input  wire [6:0]   i_roi_pct,   // 25..100 (100 = 全画幅)

	output reg          o_tvalid,
	output reg          o_tuser,
	output reg          o_tlast,
	output reg  [127:0] o_rgb
);

	//============================================================== ROI 窗口
	// 百分比量化到档位 (避免除法)
	wire [2:0] roi_sel = (i_roi_pct >= 7'd88) ? 3'd0 :   // 100%
	                     (i_roi_pct >= 7'd63) ? 3'd1 :   // 75%
	                     (i_roi_pct >= 7'd44) ? 3'd2 :   // 50%
	                     (i_roi_pct >= 7'd31) ? 3'd3 :   // 37.5%
	                     (i_roi_pct >= 7'd19) ? 3'd4 :   // 25%
	                                            3'd5;    // 12.5%

	// 全部用移位/加减, 无除法器
	wire [11:0] pw = i_h_active;
	wire [11:0] ph = i_v_active;
	wire [11:0] roi_w = (roi_sel == 3'd0) ? pw :                          // 1
	                    (roi_sel == 3'd1) ? (pw - (pw >> 2)) :            // 3/4
	                    (roi_sel == 3'd2) ? (pw >> 1) :                   // 1/2
	                    (roi_sel == 3'd3) ? ((pw >> 1) - (pw >> 3)) :     // 3/8
	                    (roi_sel == 3'd4) ? (pw >> 2) :                   // 1/4
	                                        (pw >> 3);                    // 1/8
	wire [11:0] roi_h = (roi_sel == 3'd0) ? ph :
	                    (roi_sel == 3'd1) ? (ph - (ph >> 2)) :
	                    (roi_sel == 3'd2) ? (ph >> 1) :
	                    (roi_sel == 3'd3) ? ((ph >> 1) - (ph >> 3)) :
	                    (roi_sel == 3'd4) ? (ph >> 2) :
	                                        (ph >> 3);
	wire [11:0] roi_x0 = (pw - roi_w) >> 1;
	wire [11:0] roi_y0 = (ph - roi_h) >> 1;

	//-------------------------------------------------------------- 行列坐标
	reg [11:0] col;     // 当前行的像素列 (0 .. H_ACTIVE-1)
	reg [11:0] row;     // 当前行号
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			col <= 12'd0;
			row <= 12'd0;
		end else if (i_tvalid) begin
			if (i_tuser) begin
				col <= PX_PER_CLK[11:0];      // 本组已消耗 PX_PER_CLK 个像素
				row <= 12'd0;
			end else if (i_tlast) begin
				col <= 12'd0;
				row <= row + 12'd1;
			end else begin
				col <= col + PX_PER_CLK[11:0];
			end
		end
	end

	// 本拍这一组 4 像素是否落在窗口内 (整组判断, 边界最多差 3 个像素, 看不出来)
	wire in_roi = (col >= roi_x0) && (col < (roi_x0 + roi_w)) &&
	              (row >= roi_y0) && (row < (roi_y0 + roi_h));

	//============================================================== 白平衡增益
	// 4 个像素, 每个 32 位 {8'h00, R, G, B} —— 高 8 位是填充, 不参与
	function [7:0] gain8;
		input [7:0] v;
		input [7:0] g;
		reg [15:0] t;
		begin
			t = v * g;                    // 最大 255*255 = 65025
			gain8 = t[14:7] + t[6];       // (v*g + 64) >> 7 的近似四舍五入
		end
	endfunction

	wire [7:0] wb_gain_r = i_wb_r;
	wire [7:0] wb_gain_b = i_wb_b;

	// 对每个像素的 R/B 做增益; 128 时结果等于原值 (t = v*128, [14:7] = v)
	wire [31:0] p0 = i_rgb[ 31: 0];
	wire [31:0] p1 = i_rgb[ 63:32];
	wire [31:0] p2 = i_rgb[ 95:64];
	wire [31:0] p3 = i_rgb[127:96];

	wire [31:0] g0 = {8'h00, gain8(p0[23:16], wb_gain_r), p0[15:8], gain8(p0[7:0], wb_gain_b)};
	wire [31:0] g1 = {8'h00, gain8(p1[23:16], wb_gain_r), p1[15:8], gain8(p1[7:0], wb_gain_b)};
	wire [31:0] g2 = {8'h00, gain8(p2[23:16], wb_gain_r), p2[15:8], gain8(p2[7:0], wb_gain_b)};
	wire [31:0] g3 = {8'h00, gain8(p3[23:16], wb_gain_r), p3[15:8], gain8(p3[7:0], wb_gain_b)};

	wire [127:0] wb_rgb = i_mono ? i_rgb : {g3, g2, g1, g0};

	// 窗口外填视频黑 (RGB=0)
	wire [127:0] out_rgb = in_roi ? wb_rgb : 128'd0;

	//============================================================== 输出寄存
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			o_tvalid <= 1'b0;
			o_tuser  <= 1'b0;
			o_tlast  <= 1'b0;
			o_rgb    <= 128'd0;
		end else begin
			o_tvalid <= i_tvalid;
			o_tuser  <= i_tuser;
			o_tlast  <= i_tlast;
			o_rgb    <= out_rgb;
		end
	end

endmodule
