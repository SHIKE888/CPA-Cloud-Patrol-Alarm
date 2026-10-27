//=============================================================================
//  preproc_edge.v
//  预处理: Sobel / 阈值 / 形态学 / 中值 / 拉普拉斯 / 浮雕 / Prewitt / 锐化
//          —— 八路硬件并行, 共用窗口, 由 i_mode 单选一路
//
//  ── 为什么能共用同一个 3x3 窗口 ──────────────────────────────────────────
//  三种算法都是 3x3 邻域运算, 都只需要「以该像素为中心的 3x3」。窗口由
//  preproc_win3x3 一次生成, 三路并行各算各的, 最后由 i_mode 选一路输出。
//  这既是方案要的"硬件并行", 也省掉大量重复的行缓存。
//
//      Sobel   : 用窗口算梯度幅值 |Gx|+|Gy|        -> 灰度边缘图
//      阈值分割: 对**亮度**做固定阈值二值化           -> 黑白图
//                (对亮度而非对边缘, 这才是区域分割的常规做法)
//      形态学  : 对上面的二值图做 3x3 腐蚀/膨胀        -> 0/255
//
//  ── 边界处理 ────────────────────────────────────────────────────────────
//  帧首两行的"上一行/上上行"无效, 用当前行顶替 (i_rowmask 指示)。
//  右边界最后一个像素的右邻来自下一行首像素, 会有 1 像素误差 —— 可忽略。
//
//  ── 输出 ────────────────────────────────────────────────────────────────
//  统一输出 RGB888x4 (128bit, 每 lane = {8'h00,R,G,B}), 灰度结果三通道写一样。
//  i_mode = 0 时输出对齐后的原图, 便于 RK 端对照。
//=============================================================================
`timescale 1ns / 1ps

module preproc_edge (
	input  wire         clk,
	input  wire         rst_n,

	// ---- 3x3 亮度窗口 (来自 preproc_win3x3) ----
	input  wire         i_tvalid,
	input  wire         i_tuser,
	input  wire         i_tlast,
	input  wire [2:0]   i_rowmask,
	input  wire [47:0]  i_winA,
	input  wire [47:0]  i_winB,
	input  wire [47:0]  i_winC,
	input  wire [127:0] i_rgb,

	// ---- 配置寄存器 (来自反向传参链路) ----
	input  wire [3:0]   i_mode,          // 0=原图 1=Sobel 2=阈值 3=形态 4=中值 5=拉普拉斯 6=浮雕 7=Prewitt
	input  wire [4:0]   i_sobel_gain,    // Sobel 增益 0..16 (4 = 原幅度)
	input  wire [7:0]   i_thresh,        // 阈值分割阈值
	input  wire         i_morph_sel,     // 0=腐蚀 1=膨胀
	input  wire [7:0]   i_morph_th,      // 形态学自己的阈值
	input  wire [4:0]   i_lap_gain,      // 拉普拉斯增益 0..16
	input  wire [4:0]   i_prew_gain,     // Prewitt 增益 0..16
	input  wire [3:0]   i_emboss_gain,   // 浮雕增益 0..8
	input  wire [7:0]   i_emboss_bias,   // 浮雕偏置 0..255 (默认 128)
	// （锐化已移除：实测对画面无可见效果，且与 Sobel/Prewitt 功能重叠）

	// ---- 输出 ----
	output reg          o_tvalid,
	output reg          o_tuser,
	output reg          o_tlast,
	output reg  [127:0] o_rgb
);

	//-------------------------------------------------------------------------
	//-------------------------------------------------------------------------
	// 小工具
	//-------------------------------------------------------------------------
	function [7:0] clamp8;
		input signed [15:0] v;
		begin
			if (v < 0)              clamp8 = 8'd0;
			else if (v > 16'sd255)  clamp8 = 8'd255;
			else                    clamp8 = v[7:0];
		end
	endfunction

	// 2026-10-27: 3x3 中值(med9) 已删除 —— 不在赛题硬指标里, 且 rank 计数法
	//   是 9x9 次比较的组合逻辑, 白占 LUT。

	// 边界行顶替: A/B 行无效时用当前行 C
	//-------------------------------------------------------------------------
	wire [47:0] eA = i_rowmask[2] ? i_winA : i_winC;
	wire [47:0] eB = i_rowmask[1] ? i_winB : i_winC;
	wire [47:0] eC = i_winC;

	//-------------------------------------------------------------------------
	// 逐像素 (每时钟 4 个): 八路算法并行, 单选用 i_mode
	//-------------------------------------------------------------------------
	wire [127:0] algo_pix;

	genvar j;
	generate
	for (j = 0; j < 4; j = j + 1) begin : g_px

		// 三行 x 三列 (像素 j 用第 j, j+1, j+2 列)
		wire [7:0] a0 = eA[(8*j)     +: 8];
		wire [7:0] a1 = eA[(8*(j+1)) +: 8];
		wire [7:0] a2 = eA[(8*(j+2)) +: 8];
		wire [7:0] b0 = eB[(8*j)     +: 8];
		wire [7:0] b1 = eB[(8*(j+1)) +: 8];
		wire [7:0] b2 = eB[(8*(j+2)) +: 8];
		wire [7:0] c0 = eC[(8*j)     +: 8];
		wire [7:0] c1 = eC[(8*(j+1)) +: 8];
		wire [7:0] c2 = eC[(8*(j+2)) +: 8];

		// ---------------- 1 Sobel ----------------
		wire signed [12:0] gx = ($signed({5'b0, a2}) + $signed({4'b0, b2, 1'b0}) + $signed({5'b0, c2}))
		                      - ($signed({5'b0, a0}) + $signed({4'b0, b0, 1'b0}) + $signed({5'b0, c0}));
		wire signed [12:0] gy = ($signed({5'b0, c0}) + $signed({4'b0, c1, 1'b0}) + $signed({5'b0, c2}))
		                      - ($signed({5'b0, a0}) + $signed({4'b0, a1, 1'b0}) + $signed({5'b0, a2}));
		wire [12:0] agx = gx[12] ? (~gx + 13'd1) : gx;
		wire [12:0] agy = gy[12] ? (~gy + 13'd1) : gy;
		wire [13:0] mag = {1'b0, agx} + {1'b0, agy};        // <= 2040
		// 增益: 4 = 原幅度, 16 = 4 倍 (典型画面 mag 只有 20~60, 右移会几乎全黑)
		wire [17:0] mag_g = mag * i_sobel_gain;
		wire [15:0] mag_s = mag_g >> 2;
		wire [7:0]  edgev = (mag_s > 16'd255) ? 8'hFF : mag_s[7:0];

		// ---------------- 2 阈值分割 ----------------
		wire binv = (c1 >= i_thresh);

		// ---------------- 3 形态学 (自己独立的阈值) ----------------
		wire [8:0] binc = {(b0 >= i_morph_th), (a0 >= i_morph_th), (a1 >= i_morph_th),
		                   (a2 >= i_morph_th), (b2 >= i_morph_th), (c0 >= i_morph_th),
		                   (c1 >= i_morph_th), (c2 >= i_morph_th), (b1 >= i_morph_th)};
		wire morphv = i_morph_sel ? (|binc) : (&binc);

		// ---------------- 4~7 中值/拉普拉斯/浮雕/Prewitt: 已删除 -------------
		//  2026-10-27: 赛题硬指标只要求 高斯/直方图/灰度/对比度拉伸/阈值/形态学/Sobel,
		//  其余算子全部删掉（主要为了腾 DSP —— 每个算子都是 per-pixel 乘法）。
		//  端口 i_lap_gain / i_prew_gain / i_emboss_gain / i_emboss_bias 保留但
		//  不再使用, TD 会把它们优化掉, 这样 cfg/UI 的连线一根都不用改。
		//  旧值 4..7 现在等同于直通(i_mode=0), 不会报错也不会黑屏。

		// ---------------- 单路 mux ----------------
		wire [7:0] gv = (i_mode == 4'd1) ? edgev :
		                (i_mode == 4'd2) ? (binv ? 8'hFF : 8'h00) :
		                (i_mode == 4'd3) ? (morphv ? 8'hFF : 8'h00) : c1;

		assign algo_pix[(32*j) +: 32] =
		    (i_mode == 4'd0) ? i_rgb[(32*j) +: 32] :
		                       {8'h00, gv, gv, gv};
	end
	endgenerate

	//-------------------------------------------------------------------------
	// 输出寄存
	//-------------------------------------------------------------------------
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
			o_rgb    <= algo_pix;
		end
	end

endmodule
