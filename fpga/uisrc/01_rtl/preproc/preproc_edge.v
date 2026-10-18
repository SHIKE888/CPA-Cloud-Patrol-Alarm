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
	input  wire [3:0]   i_mode,          // 0=原图 1=Sobel 2=阈值 3=形态 4=中值 5=拉普拉斯 6=浮雕 7=Prewitt 8=锐化
	input  wire [4:0]   i_sobel_gain,    // Sobel 增益 0..16 (4 = 原幅度)
	input  wire [7:0]   i_thresh,        // 阈值分割阈值
	input  wire         i_morph_sel,     // 0=腐蚀 1=膨胀
	input  wire [7:0]   i_morph_th,      // 形态学自己的阈值
	input  wire [4:0]   i_lap_gain,      // 拉普拉斯增益 0..16
	input  wire [4:0]   i_prew_gain,     // Prewitt 增益 0..16
	input  wire [3:0]   i_emboss_gain,   // 浮雕增益 0..8
	input  wire [7:0]   i_emboss_bias,   // 浮雕偏置 0..255 (默认 128)
	input  wire [4:0]   i_sharp_gain,    // 锐化增益 0..16

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

	// 3x3 中值: rank 计数法 (严格中值, 含重值处理)
	//   rank[i] = #{j: x[j] < x[i]} + #{j<i: x[j] == x[i]}
	//   rank 恰好是 0..8 的一个排列, 取 rank==4 的那个值即为中值。
	function [7:0] med9;
		input [7:0] v0, v1, v2, v3, v4, v5, v6, v7, v8;
		reg [7:0] x [0:8];
		reg [3:0] r [0:8];
		integer i, j;
		begin
			x[0] = v0; x[1] = v1; x[2] = v2;
			x[3] = v3; x[4] = v4; x[5] = v5;
			x[6] = v6; x[7] = v7; x[8] = v8;
			for (i = 0; i < 9; i = i + 1) begin
				r[i] = 4'd0;
				for (j = 0; j < 9; j = j + 1) begin
					if (i < j) r[i] = r[i] + ((x[j] <  x[i]) ? 4'd1 : 4'd0);
					if (i > j) r[i] = r[i] + ((x[j] <= x[i]) ? 4'd1 : 4'd0);
				end
			end
			med9 = 8'd0;
			for (i = 0; i < 9; i = i + 1)
				if (r[i] == 4'd4) med9 = x[i];
		end
	endfunction

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

		// ---------------- 4 中值 ----------------
		wire [7:0] medv = med9(a0, a1, a2, b0, b1, b2, c0, c1, c2);

		// ---------------- 5 拉普拉斯 ----------------
		wire signed [12:0] lsum = ($signed({5'b0, b1}) <<< 2)
		                        - $signed({5'b0, a1}) - $signed({5'b0, c1})
		                        - $signed({5'b0, b0}) - $signed({5'b0, b2});
		wire [12:0] alsum = lsum[12] ? (~lsum + 13'd1) : lsum;
		wire [16:0] al_g  = alsum * i_lap_gain;
		wire [14:0] al_s  = al_g >> 2;
		wire [7:0]  lapv  = (al_s > 15'd255) ? 8'hFF : al_s[7:0];

		// ---------------- 6 浮雕 (独立增益/偏置) ----------------
		// kernel [-2 -1 0; -1 1 1; 0 1 2]
		wire signed [12:0] ebase = ($signed({4'b0, c2, 1'b0}) + $signed({5'b0, c1})
		                          + $signed({5'b0, b2}) + $signed({5'b0, b1}))
		                         - ($signed({4'b0, a0, 1'b0}) + $signed({5'b0, a1})
		                          + $signed({5'b0, b0}));
		wire signed [15:0] egain = (ebase * $signed({12'b0, i_emboss_gain})) >>> 3;
		wire [7:0] embv = clamp8($signed({8'd0, i_emboss_bias}) + egain);

		// ---------------- 7 Prewitt ----------------
		wire signed [10:0] px = ($signed({3'b0, a2}) + $signed({3'b0, b2}) + $signed({3'b0, c2}))
		                      - ($signed({3'b0, a0}) + $signed({3'b0, b0}) + $signed({3'b0, c0}));
		wire signed [10:0] py = ($signed({3'b0, c0}) + $signed({3'b0, c1}) + $signed({3'b0, c2}))
		                      - ($signed({3'b0, a0}) + $signed({3'b0, a1}) + $signed({3'b0, a2}));
		wire [10:0] apx = px[10] ? (~px + 11'd1) : px;
		wire [10:0] apy = py[10] ? (~py + 11'd1) : py;
		wire [11:0] pmag = {1'b0, apx} + {1'b0, apy};      // <= 1530
		wire [15:0] pmag_g = pmag * i_prew_gain;
		wire [13:0] pmag_s = pmag_g >> 2;
		wire [7:0]  prewv = (pmag_s > 14'd255) ? 8'hFF : pmag_s[7:0];

		// ---------------- 8 锐化 (保色) ----------------
		wire signed [12:0] dsh = ($signed({5'b0, b1}) <<< 2)
		                       - $signed({5'b0, a1}) - $signed({5'b0, b0})
		                       - $signed({5'b0, b2}) - $signed({5'b0, c1});
		wire signed [15:0] shadd = (dsh * $signed({11'b0, i_sharp_gain})) >>> 4;

		wire [7:0] rp = i_rgb[(32*j) + 16 +: 8];
		wire [7:0] gp = i_rgb[(32*j) +  8 +: 8];
		wire [7:0] bp = i_rgb[(32*j)      +: 8];

		// ---------------- 单路 mux ----------------
		wire [7:0] gv = (i_mode == 4'd1) ? edgev :
		                (i_mode == 4'd2) ? (binv ? 8'hFF : 8'h00) :
		                (i_mode == 4'd3) ? (morphv ? 8'hFF : 8'h00) :
		                (i_mode == 4'd4) ? medv :
		                (i_mode == 4'd5) ? lapv :
		                (i_mode == 4'd6) ? embv :
		                (i_mode == 4'd7) ? prewv : c1;

		assign algo_pix[(32*j) +: 32] =
		    (i_mode == 4'd0) ? i_rgb[(32*j) +: 32] :
		    (i_mode == 4'd8) ? {8'h00,
		                        clamp8($signed({8'd0, rp}) + shadd),
		                        clamp8($signed({8'd0, gp}) + shadd),
		                        clamp8($signed({8'd0, bp}) + shadd)} :
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
