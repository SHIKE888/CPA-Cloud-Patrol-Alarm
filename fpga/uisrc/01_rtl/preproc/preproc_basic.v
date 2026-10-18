//=============================================================================
//  preproc_basic.v
//  初级预处理层: 灰度化 / 高斯滤波 / 直方图均衡 / 对比度拉伸 / 反色
//
//  ── 赛题要求 ────────────────────────────────────────────────────────────
//  灰度化、高斯滤波、直方图均衡**三套硬件必须并行实现**（不是三选一）。
//  本模块把五路算法全部同时例化/同时钟计算, 由 i_en 位图决定"用不用它的结果":
//      bit0 灰度化    bit1 高斯    bit2 直方图均衡
//      bit3 对比度    bit4 反色
//  位图 = 0 时输出 = 对齐延迟后的原图（模块仍在跑, 满足"必须并行"）。
//
//  ── 固定组合顺序（与位图无关） ───────────────────────────────────────────
//      输入 → [高斯] → [直方图均衡] → [灰度] → [对比度] → [反色] → 输出
//  这样同样的位图永远得到同样的画面, 网页可以直接显示"当前处理链"。
//
//  ── 为什么用"亮度差值"做高斯/均衡（保色） ───────────────────────────────
//  高斯只平滑亮度, 再把 (Y_smooth - Y) 加到 R/G/B 上; 直方图均衡同理。
//  好处: 只占一套亮度行缓冲, 且颜色不会因平滑/均衡而偏移。
//
//  ── 直方图均衡实现要点 ──────────────────────────────────────────────────
//  1) 每时钟 4 像素 -> 4 个 bank 轮转, 每拍只统计 1 个 lane (≈1/4 采样),
//     避免多写口冲突, 也避免均匀画面下同一 bin 连续 +1 的读改写覆盖。
//  2) 帧尾(行计数到 v_active)进入场消隐后构建 CDF/LUT, 约 1300 拍;
//     1080p 场消隐 ~99k 拍, 4K 更长 => 不需要双缓冲。
//  3) 纯色画面 (total == cdfmin) 跳过构建, 保留上一帧 LUT, 避免整幅变黑。
//
//  ── 时序 ────────────────────────────────────────────────────────────────
//  窗口 4 拍 + 3 级输出流水; 不改变行结构 (进多少行出多少行)。
//=============================================================================
`timescale 1ns / 1ps

module preproc_basic #(
	parameter integer PX_PER_CLK = 4
)(
	input  wire         clk,
	input  wire         rst_n,
	input  wire [12:0]  i_h_active,
	input  wire [11:0]  i_v_active,

	// ---- 视频输入 (RGB888x4, 每 lane = {8'h00,R,G,B}) ----
	input  wire         i_tvalid,
	input  wire         i_tuser,
	input  wire         i_tlast,
	input  wire [127:0] i_rgb,

	// ---- 配置 (准静态, cfg_ctrl_top 2 级同步后给出) ----
	input  wire [4:0]   i_en,           // bit0 灰度 bit1 高斯 bit2 HE bit3 对比度 bit4 反色
	input  wire         i_gray_mode,    // 0=BT.601  1=BT.709
	input  wire [3:0]   i_gauss_str,    // 0..8
	input  wire [7:0]   i_he_str,       // 0..255
	input  wire [3:0]   i_contrast,     // 0..8

	// ---- 视频输出 ----
	output reg          o_tvalid,
	output reg          o_tuser,
	output reg          o_tlast,
	output reg  [127:0] o_rgb
);

	//-------------------------------------------------------------------------
	// 0. 工具函数
	//-------------------------------------------------------------------------
	function [7:0] lum_sel;
		input [7:0]           r;
		input [7:0]           g;
		input [7:0]           b;
		input                 mode;      // 0=601  1=709
		reg   [15:0]          t;
		begin
			// BT.601: (77,150,29)   BT.709: (54,183,19)   系数和都是 256
			t = mode ? (54 * r + 183 * g + 19 * b)
			         : (77 * r + 150 * g + 29 * b);
			lum_sel = t[15:8];
		end
	endfunction

	function [7:0] clamp8;
		input signed [15:0] v;
		begin
			if (v < 0)              clamp8 = 8'd0;
			else if (v > 16'sd255)  clamp8 = 8'd255;
			else                    clamp8 = v[7:0];
		end
	endfunction

	function [7:0] contrast8;
		input [7:0] c;
		input [3:0] g;
		reg signed [15:0] t;
		begin
			t = ($signed({8'd0, c}) - 16'sd128) * $signed({12'd0, g} + 16'sd8);
			t = (t >>> 3) + 16'sd128;
			contrast8 = clamp8(t);
		end
	endfunction

	//-------------------------------------------------------------------------
	// 1. 3x3 亮度窗口 (与高级预处理共用同一套生成器结构)
	//-------------------------------------------------------------------------
	wire         w_tvalid, w_tuser, w_tlast;
	wire [2:0]   w_rowmask;
	wire [47:0]  w_winA, w_winB, w_winC;
	wire [127:0] w_rgb;

	preproc_win3x3 #(
		.PX_PER_CLK (PX_PER_CLK)
	) u_win (
		.clk       (clk),
		.rst_n     (rst_n),
		.I_nw      ({3'd0, (i_h_active >> 2)}),
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

	wire [47:0] eA = w_rowmask[2] ? w_winA : w_winC;
	wire [47:0] eB = w_rowmask[1] ? w_winB : w_winC;
	wire [47:0] eC = w_winC;

	// 本组 4 个像素的中心亮度 (窗口字节 b1..b4)
	wire [7:0] c_l0 = w_winC[15: 8];
	wire [7:0] c_l1 = w_winC[23:16];
	wire [7:0] c_l2 = w_winC[31:24];
	wire [7:0] c_l3 = w_winC[39:32];

	//-------------------------------------------------------------------------
	// 2. 直方图统计 (4 bank 轮转, 每拍 1 个 lane)
	//-------------------------------------------------------------------------
	reg [23:0] hist0 [0:255];
	reg [23:0] hist1 [0:255];
	reg [23:0] hist2 [0:255];
	reg [23:0] hist3 [0:255];

	wire [7:0] in_l0 = lum_sel(i_rgb[23:16], i_rgb[15:8], i_rgb[7:0], i_gray_mode);
	wire [7:0] in_l1 = lum_sel(i_rgb[55:48], i_rgb[47:40], i_rgb[39:32], i_gray_mode);
	wire [7:0] in_l2 = lum_sel(i_rgb[87:80], i_rgb[79:72], i_rgb[71:64], i_gray_mode);
	wire [7:0] in_l3 = lum_sel(i_rgb[119:112], i_rgb[111:104], i_rgb[103:96], i_gray_mode);

	reg [1:0]  hsel;
	reg [1:0]  hsel_d;
	reg        hcnt_en_d;
	reg [7:0]  haddr_d;
	reg [23:0] hq0, hq1, hq2, hq3;

	wire [7:0] hsel_lum = (hsel == 2'd0) ? in_l0 :
	                      (hsel == 2'd1) ? in_l1 :
	                      (hsel == 2'd2) ? in_l2 : in_l3;

	//-------------------------------------------------------------------------
	// 3. LUT (4 个 bank, 每 lane 一个读口)
	//-------------------------------------------------------------------------
	reg [7:0] lut0 [0:255];
	reg [7:0] lut1 [0:255];
	reg [7:0] lut2 [0:255];
	reg [7:0] lut3 [0:255];

	reg [7:0] lq0, lq1, lq2, lq3;

	//-------------------------------------------------------------------------
	// 4. 构建状态机
	//-------------------------------------------------------------------------
	localparam [2:0] S_IDLE = 3'd0,
	                 S_WAIT = 3'd1,
	                 S_SUM  = 3'd2,
	                 S_DIV  = 3'd3,
	                 S_LUT  = 3'd4,
	                 S_CLR  = 3'd5,
	                 S_INIT = 3'd6;   // 上电: 清直方图 + LUT 写成单位映射

	reg [2:0]  st;
	reg [5:0]  wait_cnt;
	reg [7:0]  bin;
	reg        phase;
	reg [25:0] cdf, cdfmin, total;
	reg [25:0] cdf2;
	reg [24:0] scale;
	reg [7:0]  lutv;

	reg [5:0]  dv_i;
	reg [31:0] dv_n, dv_r, dv_q;
	reg [31:0] nx_r, nx_n, nx_q;

	wire [25:0] hsum_now = hq0 + hq1 + hq2 + hq3;

	wire [7:0] raddr = ((st == S_SUM) || (st == S_LUT)) ? bin : hsel_lum;

	// ★ 声明必须在 always 之前
	wire [25:0] cdf_n    = cdf + hsum_now;
	wire [25:0] cdfmin_n = (cdf == 26'd0 && hsum_now != 26'd0) ? cdf_n : cdfmin;
	wire [25:0] cdf2_n   = cdf2 + hsum_now;
	wire [25:0] lut_rel  = (cdf2_n >= cdfmin) ? (cdf2_n - cdfmin) : 26'd0;
	wire [51:0] lut_prod = lut_rel * scale + 52'd2048;   // +0.5 四舍五入
	wire [25:0] lut_div  = lut_prod >> 12;
	wire [7:0]  lutv_n   = (lut_div > 26'd255) ? 8'hFF : lut_div[7:0];

	// 帧尾检测 (不依赖 tuser —— 本工程实测 S_ISP_O_tuser 恒 0)
	reg [11:0] row_cnt;
	reg        build_req;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			row_cnt   <= 12'd0;
			build_req <= 1'b0;
		end else begin
			build_req <= 1'b0;
			if (i_tvalid && i_tuser) begin
				row_cnt <= 12'd0;
			end else if (i_tvalid && i_tlast && (i_v_active != 12'd0)) begin
				if ((row_cnt + 12'd1) >= i_v_active) begin
					row_cnt   <= 12'd0;
					build_req <= 1'b1;
				end else begin
					row_cnt <= row_cnt + 12'd1;
				end
			end
		end
	end

	//-------------------------------------------------------------------------
	// 5. 直方图 RAM (读口 + 写口同一 always 块)
	//-------------------------------------------------------------------------
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			hsel      <= 2'd0;
			hsel_d    <= 2'd0;
			hcnt_en_d <= 1'b0;
			haddr_d   <= 8'd0;
			hq0 <= 24'd0; hq1 <= 24'd0; hq2 <= 24'd0; hq3 <= 24'd0;
		end else begin
			hsel      <= hsel + 2'd1;
			hsel_d    <= hsel;
			hcnt_en_d <= i_tvalid;
			haddr_d   <= hsel_lum;

			hq0 <= hist0[raddr];
			hq1 <= hist1[raddr];
			hq2 <= hist2[raddr];
			hq3 <= hist3[raddr];

			if (st == S_CLR || st == S_INIT) begin
				hist0[bin] <= 24'd0;
				hist1[bin] <= 24'd0;
				hist2[bin] <= 24'd0;
				hist3[bin] <= 24'd0;
			end else if ((st == S_IDLE) && hcnt_en_d) begin
				case (hsel_d)
					2'd0: hist0[haddr_d] <= hq0 + 24'd1;
					2'd1: hist1[haddr_d] <= hq1 + 24'd1;
					2'd2: hist2[haddr_d] <= hq2 + 24'd1;
					default: hist3[haddr_d] <= hq3 + 24'd1;
				endcase
			end
		end
	end

	//-------------------------------------------------------------------------
	// 6. LUT RAM (读口给像素路径, 写口给状态机)
	//-------------------------------------------------------------------------
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			lq0 <= 8'd0; lq1 <= 8'd0; lq2 <= 8'd0; lq3 <= 8'd0;
		end else begin
			lq0 <= lut0[c_l0];
			lq1 <= lut1[c_l1];
			lq2 <= lut2[c_l2];
			lq3 <= lut3[c_l3];

			if (st == S_INIT) begin
				// 上电: LUT 先写成单位映射, 保证 HE 第一帧不会是黑/随机
				lut0[bin] <= bin;
				lut1[bin] <= bin;
				lut2[bin] <= bin;
				lut3[bin] <= bin;
			end else if ((st == S_LUT) && phase) begin
				lut0[bin] <= lutv_n;
				lut1[bin] <= lutv_n;
				lut2[bin] <= lutv_n;
				lut3[bin] <= lutv_n;
			end
		end
	end

	//-------------------------------------------------------------------------
	// 7. 构建 FSM
	//-------------------------------------------------------------------------
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			st       <= S_INIT;      // 先清直方图 + 单位 LUT
			wait_cnt <= 6'd0;
			bin      <= 8'd0;
			phase    <= 1'b0;
			cdf      <= 26'd0;
			cdfmin   <= 26'd0;
			total    <= 26'd0;
			cdf2     <= 26'd0;
			scale    <= 25'd0;
			lutv     <= 8'd0;
			dv_i     <= 6'd0;
			dv_n     <= 32'd0;
			dv_r     <= 32'd0;
			dv_q     <= 32'd0;
			nx_r     <= 32'd0;
			nx_n     <= 32'd0;
			nx_q     <= 32'd0;
		end else begin
			case (st)
				// 上电初始化: 清直方图 + LUT 单位映射 (256 拍)
				S_INIT: begin
					if (bin == 8'd255) begin
						st  <= S_IDLE;
						bin <= 8'd0;
					end else begin
						bin <= bin + 8'd1;
					end
				end

				S_IDLE: begin
					if (build_req) begin
						st       <= S_WAIT;
						wait_cnt <= 6'd0;
					end
				end

				S_WAIT: begin
					if (wait_cnt == 6'd15) begin
						st     <= S_SUM;
						bin    <= 8'd0;
						phase  <= 1'b0;
						cdf    <= 26'd0;
						cdfmin <= 26'd0;
						total  <= 26'd0;
					end else begin
						wait_cnt <= wait_cnt + 6'd1;
					end
				end

				// pass 1: 求 total / cdfmin
				S_SUM: begin
					if (!phase) begin
						phase <= 1'b1;
					end else begin
						if (bin == 8'd255) begin
							total  <= cdf_n;
							cdfmin <= cdfmin_n;
							scale  <= 25'd0;
							dv_i   <= 6'd0;
							if ((cdf_n - cdfmin_n) == 26'd0) begin
								st  <= S_CLR;       // 纯色: 跳过, 保留旧 LUT
								bin <= 8'd0;
							end else begin
								st  <= S_DIV;
							end
						end else begin
							cdf    <= cdf_n;
							cdfmin <= cdfmin_n;
							bin    <= bin + 8'd1;
							phase  <= 1'b0;
						end
					end
				end

				// 一次除法: scale = (255<<12) / (total - cdfmin)
				S_DIV: begin
					if (dv_i == 6'd0) begin
						dv_n <= 32'd1_044_480;      // 255 << 12
						dv_r <= 32'd0;
						dv_q <= 32'd0;
						dv_i <= 6'd32;
					end else begin
						nx_r = {dv_r[30:0], dv_n[31]};
						nx_n = {dv_n[30:0], 1'b0};
						nx_q = {dv_q[30:0], 1'b0};
						if (nx_r >= {6'd0, (total - cdfmin)}) begin
							nx_r   = nx_r - {6'd0, (total - cdfmin)};
							nx_q[0] = 1'b1;
						end
						dv_r <= nx_r;
						dv_n <= nx_n;
						dv_q <= nx_q;
						dv_i <= dv_i - 6'd1;
						if (dv_i == 6'd1) begin
							scale <= nx_q[24:0];
							st    <= S_LUT;
							bin   <= 8'd0;
							phase <= 1'b0;
							cdf2  <= 26'd0;
						end
					end
				end

				// pass 2: 再累加 CDF, 逐 bin 写 LUT
				S_LUT: begin
					if (!phase) begin
						phase <= 1'b1;
					end else begin
						cdf2 <= cdf2_n;
						lutv <= lutv_n;
						if (bin == 8'd255) begin
							st  <= S_CLR;
							bin <= 8'd0;
						end else begin
							bin   <= bin + 8'd1;
							phase <= 1'b0;
						end
					end
				end

				S_CLR: begin
					if (bin == 8'd255) begin
						st  <= S_IDLE;
						bin <= 8'd0;
					end else begin
						bin <= bin + 8'd1;
					end
				end

				default: st <= S_IDLE;
			endcase
		end
	end

	//-------------------------------------------------------------------------
	// 8. Stage 0: 高斯差值 + 混合 (组合) -> 寄存
	//-------------------------------------------------------------------------
	wire [127:0] gauss_mix;
	wire [127:0] rgb_stage0;

	genvar j;
	generate
	for (j = 0; j < 4; j = j + 1) begin : g_px
		wire [7:0] a0 = eA[(8*j)     +: 8];
		wire [7:0] a1 = eA[(8*(j+1)) +: 8];
		wire [7:0] a2 = eA[(8*(j+2)) +: 8];
		wire [7:0] b0 = eB[(8*j)     +: 8];
		wire [7:0] b1 = eB[(8*(j+1)) +: 8];
		wire [7:0] b2 = eB[(8*(j+2)) +: 8];
		wire [7:0] c0 = eC[(8*j)     +: 8];
		wire [7:0] c1 = eC[(8*(j+1)) +: 8];
		wire [7:0] c2 = eC[(8*(j+2)) +: 8];

		// 3x3 二项式核, 归一化 /16  (<= 4080)
		wire [11:0] gsum = {4'b0, a0} + {3'b0, a1, 1'b0} + {4'b0, a2}
		                 + {3'b0, b0, 1'b0} + {2'b0, b1, 2'b0} + {3'b0, b2, 1'b0}
		                 + {4'b0, c0} + {3'b0, c1, 1'b0} + {4'b0, c2};
		wire [7:0]  gfull = gsum[11:4];
		wire [15:0] gblend = gfull * i_gauss_str
		                   + c1 * (8'd8 - {4'b0, i_gauss_str});
		wire [7:0]  gv = gblend[10:3];
		wire signed [15:0] gd = $signed({8'd0, gv}) - $signed({8'd0, c1});

		wire [7:0] rp = w_rgb[(32*j) + 16 +: 8];
		wire [7:0] gp = w_rgb[(32*j) +  8 +: 8];
		wire [7:0] bp = w_rgb[(32*j)      +: 8];

		assign gauss_mix[(32*j) +: 32] = {8'h00,
			clamp8($signed({8'd0, rp}) + (i_en[1] ? gd : 16'sd0)),
			clamp8($signed({8'd0, gp}) + (i_en[1] ? gd : 16'sd0)),
			clamp8($signed({8'd0, bp}) + (i_en[1] ? gd : 16'sd0))};
	end
	endgenerate

	assign rgb_stage0 = gauss_mix;

	reg         v1, u1, t1;
	reg [127:0] rgb1;
	reg [31:0]  cl1;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			v1 <= 1'b0; u1 <= 1'b0; t1 <= 1'b0;
			rgb1 <= 128'd0;
			cl1  <= 32'd0;
		end else begin
			v1   <= w_tvalid;
			u1   <= w_tuser;
			t1   <= w_tlast;
			rgb1 <= rgb_stage0;
			cl1  <= {c_l3, c_l2, c_l1, c_l0};
		end
	end

	//-------------------------------------------------------------------------
	// 9. Stage 1: 直方图均衡差值 (LUT 数据已在本拍有效) -> 寄存
	//-------------------------------------------------------------------------
	wire [127:0] he_mix;
	wire [31:0]  luma_h;

	generate
	for (j = 0; j < 4; j = j + 1) begin : g_he
		wire [7:0] cl  = cl1[(8*j) +: 8];
		wire [7:0] lqv = (j == 0) ? lq0 : (j == 1) ? lq1 : (j == 2) ? lq2 : lq3;
		// 混合: str=0 -> 原亮度, str=255 -> 完全均衡
		// ⚠ 必须显式算 256-str (9 位)。若写 (8'd0 - i_he_str), Verilog 会在
		//    16 位上下文里算出 0xFF01 而不是 1, 乘法结果完全错位。
		wire [8:0]  he_inv = 9'd256 - {1'b0, i_he_str};
		wire [16:0] hblend = lqv * i_he_str + cl * he_inv + 17'd128;
		wire [7:0]  hv = hblend[15:8];
		wire signed [15:0] hd = $signed({8'd0, hv}) - $signed({8'd0, cl});

		wire [7:0] rp = rgb1[(32*j) + 16 +: 8];
		wire [7:0] gp = rgb1[(32*j) +  8 +: 8];
		wire [7:0] bp = rgb1[(32*j)      +: 8];

		wire [7:0] r2 = clamp8($signed({8'd0, rp}) + (i_en[2] ? hd : 16'sd0));
		wire [7:0] g2 = clamp8($signed({8'd0, gp}) + (i_en[2] ? hd : 16'sd0));
		wire [7:0] b2 = clamp8($signed({8'd0, bp}) + (i_en[2] ? hd : 16'sd0));

		assign he_mix[(32*j) +: 32] = {8'h00, r2, g2, b2};
		assign luma_h[(8*j)   +: 8] = lum_sel(r2, g2, b2, i_gray_mode);
	end
	endgenerate

	reg         v2, u2, t2;
	reg [127:0] rgb2;
	reg [31:0]  lum2;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			v2 <= 1'b0; u2 <= 1'b0; t2 <= 1'b0;
			rgb2 <= 128'd0;
			lum2 <= 32'd0;
		end else begin
			v2   <= v1;
			u2   <= u1;
			t2   <= t1;
			rgb2 <= he_mix;
			lum2 <= luma_h;
		end
	end

	//-------------------------------------------------------------------------
	// 10. Stage 2: 灰度 / 对比度 / 反色 -> 输出寄存
	//-------------------------------------------------------------------------
	wire [127:0] final_pix;

	generate
	for (j = 0; j < 4; j = j + 1) begin : g_out
		wire [7:0] l  = lum2[(8*j) +: 8];
		wire [7:0] rp = rgb2[(32*j) + 16 +: 8];
		wire [7:0] gp = rgb2[(32*j) +  8 +: 8];
		wire [7:0] bp = rgb2[(32*j)      +: 8];

		// 灰度: 三通道写同值
		wire [7:0] r3 = i_en[0] ? l : rp;
		wire [7:0] g3 = i_en[0] ? l : gp;
		wire [7:0] b3 = i_en[0] ? l : bp;

		// 对比度
		wire [7:0] r4 = i_en[3] ? contrast8(r3, i_contrast) : r3;
		wire [7:0] g4 = i_en[3] ? contrast8(g3, i_contrast) : g3;
		wire [7:0] b4 = i_en[3] ? contrast8(b3, i_contrast) : b3;

		// 反色
		wire [7:0] r5 = i_en[4] ? (8'hFF - r4) : r4;
		wire [7:0] g5 = i_en[4] ? (8'hFF - g4) : g4;
		wire [7:0] b5 = i_en[4] ? (8'hFF - b4) : b4;

		assign final_pix[(32*j) +: 32] = {8'h00, r5, g5, b5};
	end
	endgenerate

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			o_tvalid <= 1'b0;
			o_tuser  <= 1'b0;
			o_tlast  <= 1'b0;
			o_rgb    <= 128'd0;
		end else begin
			o_tvalid <= v2;
			o_tuser  <= u2;
			o_tlast  <= t2;
			o_rgb    <= final_pix;
		end
	end

endmodule
