//=============================================================================
//  preproc_edge.v
//  预处理 P4/P5/P6: Sobel 边缘检测 / 阈值分割 / 形态学  —— 三路并行, 共用窗口
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
	input  wire [2:0]   i_mode,          // 0=原图 1=Sobel 2=阈值 3=形态学
	input  wire [3:0]   i_sobel_shift,   // 幅度右移, 0..8 (默认 3 -> 0..255)
	input  wire [7:0]   i_thresh,        // 二值化阈值
	input  wire         i_morph_sel,     // 0=腐蚀 1=膨胀

	// ---- 输出 ----
	output reg          o_tvalid,
	output reg          o_tuser,
	output reg          o_tlast,
	output reg  [127:0] o_rgb
);

	//-------------------------------------------------------------------------
	// 边界行顶替: A/B 行无效时用当前行 C
	//-------------------------------------------------------------------------
	wire [47:0] eA = i_rowmask[2] ? i_winA : i_winC;
	wire [47:0] eB = i_rowmask[1] ? i_winB : i_winC;
	wire [47:0] eC = i_winC;

	//-------------------------------------------------------------------------
	// 逐像素 (每时钟 4 个)
	//-------------------------------------------------------------------------
	wire [127:0] out_pix;
	wire [127:0] edge_pix;
	wire [127:0] bin_pix;
	wire [127:0] morph_pix;

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

		// ---------------- P4 Sobel ----------------
		// Gx = (A2 + 2*B2 + C2) - (A0 + 2*B0 + C0)    幅度 <= 1020
		// Gy = (C0 + 2*C1 + C2) - (A0 + 2*A1 + A2)
		wire signed [12:0] gx = ($signed({5'b0, a2}) + $signed({4'b0, b2, 1'b0}) + $signed({5'b0, c2}))
		                      - ($signed({5'b0, a0}) + $signed({4'b0, b0, 1'b0}) + $signed({5'b0, c0}));
		wire signed [12:0] gy = ($signed({5'b0, c0}) + $signed({4'b0, c1, 1'b0}) + $signed({5'b0, c2}))
		                      - ($signed({5'b0, a0}) + $signed({4'b0, a1, 1'b0}) + $signed({5'b0, a2}));
		wire [12:0] agx = gx[12] ? (~gx + 13'd1) : gx;
		wire [12:0] agy = gy[12] ? (~gy + 13'd1) : gy;
		wire [13:0] mag = {1'b0, agx} + {1'b0, agy};        // <= 2040

		// 右移缩放后截顶到 8 位
		wire [13:0] mag_s = (mag >> i_sobel_shift);
		wire [7:0]  edgev = (mag_s > 14'd255) ? 8'hFF : mag_s[7:0];

		// ---------------- P5 阈值分割 (对亮度) ----------------
		wire binv = (c1 >= i_thresh);

		// ---------------- P6 形态学 (对二值图) ----------------
		// 9 个邻域位
		wire [8:0] binc = {(b0 >= i_thresh), (a0 >= i_thresh), (a1 >= i_thresh),
		                   (a2 >= i_thresh), (b2 >= i_thresh), (c0 >= i_thresh),
		                   (c1 >= i_thresh), (c2 >= i_thresh), (b1 >= i_thresh)};
		wire morphv = i_morph_sel ? (|binc) : (&binc);      // 1=膨胀(或) 0=腐蚀(与)

		// ---------------- 组装 ----------------
		assign edge_pix[(32*j) +: 32]  = {8'h00, edgev,  edgev,  edgev};
		assign bin_pix[(32*j) +: 32]   = {8'h00,
		                                  binv ? 8'hFF : 8'h00,
		                                  binv ? 8'hFF : 8'h00,
		                                  binv ? 8'hFF : 8'h00};
		assign morph_pix[(32*j) +: 32] = {8'h00,
		                                  morphv ? 8'hFF : 8'h00,
		                                  morphv ? 8'hFF : 8'h00,
		                                  morphv ? 8'hFF : 8'h00};
	end
	endgenerate

	assign out_pix = (i_mode == 3'd1) ? edge_pix  :
	                 (i_mode == 3'd2) ? bin_pix   :
	                 (i_mode == 3'd3) ? morph_pix :
	                                    i_rgb;

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
			o_rgb    <= out_pix;
		end
	end

endmodule
