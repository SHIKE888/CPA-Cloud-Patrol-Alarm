//=============================================================================
//  preproc_basic.v  (V45.2)
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
//
//  ── V45.2 三处关键修正 ──────────────────────────────────────────────────
//  1) 高斯改成**两遍 3x3**（等效 5x5，约 -50% 高频），否则 1 像素的模糊在
//     预览画面上几乎看不出来。强度 s:
//         s = 1..4 : 原图 → 一遍高斯 线性混合
//         s = 5..8 : 一遍高斯 → 两遍高斯 线性混合
//     实现: 第二遍复用第二个 preproc_win3x3, 只对亮度流做, RGB 同步延迟 4 拍。
//  2) 直方图均衡的帧尾检测**不能再用 tlast**:
//     ui_isp_top 的 O_tlast 在 ui_awb.v:303 被改成了"valid 下降沿" = 帧尾脉冲,
//     不是行尾。原来按 tlast 计行永远到不了 v_active -> LUT 一直是单位映射,
//     现象就是"开了 HE 完全没变化"。
//     现在改成按**像素组计数**分帧: 每行 nw = h_active/4 组, 累计 v_active 行。
//     (与 preproc_win3x3 内部的行地址回绕假设一致)
//  3) 直方图 RAM 上电值不确定: 复位后先 S_INIT 清直方图 + 把 LUT 写成单位映射。
//
//  ── 直方图均衡实现要点 ──────────────────────────────────────────────────
//  · 每时钟 4 像素 -> 4 个 bank 轮转, 每拍只统计 1 个 lane (≈1/4 采样);
//    每个 bank 每 4 拍才写一次, 读-加一-写回不会自我覆盖。
//  · 帧尾进入场消隐后构建 CDF/LUT (约 1300 拍), 1080p 场消隐 ~99k 拍, 余量极大。
//  · 纯色画面 (total == cdfmin) 跳过构建, 保留上一帧 LUT。
//=============================================================================
`timescale 1ns / 1ps

module preproc_basic #(
	parameter integer PX_PER_CLK = 4,
	// 调试开关: 默认值与板上 bit 一致; 仿真时可编译期改掉做 A/B
	//   P_SLOPE = LUT 每 bin 最大上升级数, 0 = 关闭斜率限制
	//   P_IIR   = 1 开启帧间 1/4 平滑, 0 关闭
	//
	//   ★ V47.8: P_IIR 默认改为 0 (关闭)。
	//   仿真(tb_he_big.v, 1920x1080 尺度, 静止场景, 帧边界严格对齐)四种组合 A/B:
	//     纯 HE          -> 帧间均值极差 102/28352 = 0.36%, 第 1 帧即锁定
	//     仅斜率限制      -> 极差 88,  第 1 帧即锁定
	//     仅 IIR         -> 极差 2352, 单调漂移 6 帧未收敛   ← 漂移的唯一来源
	//     斜率限制+IIR    -> 极差 2921, 单调漂移            ← 就是当时的板上配置
	//   lut[64] = 48,36,27,20,15,11 正好是 48*0.75^n: IIR 是时间常数 4 帧的
	//   一阶低通, 上电/切换/任何 ideal 变化后要 10~20 帧才收敛, 这段时间整帧
	//   亮度持续单调变化 —— 就是用户看到的“闪”。帧间抖动已经只有 0.36%,
	//   根本不需要 IIR; 噪点由 LUT_SLOPE 把噪声放大倍数硬限住(实测 maxslope=3)。
	parameter [8:0]   P_SLOPE   = 9'd3,
	parameter         P_IIR     = 1'b0
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

	// ---- 配置 ----
	input  wire [4:0]   i_en,           // bit0 灰度 bit1 高斯 bit2 HE bit3 对比度 bit4 反色
	input  wire         i_gray_mode,    // 0=BT.601  1=BT.709
	input  wire [3:0]   i_gauss_str,    // 0..8  (8 = 完全用滤波结果)
	input  wire [1:0]   i_gauss_ker,    // 0=3x3  1=5x5  2=7x7 (级联 1/2/3 遍 3x3)
	input  wire [7:0]   i_he_str,       // 0..255
	input  wire [7:0]   i_he_clip,      // 直方图裁上限 = i_he_clip*64, 0=不限制
	// （i_he_temp 已取消: 直方图均衡本身不应靠“防频闪”滑块掩盖频闪,
	//   现在帧间平滑固定为 1/4 IIR, 用户不可调）
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

	// 逐通道混合: s=0 -> 原图, s=8 -> 完全用滤波结果 (单调, 不会过冲)
	function [7:0] mix8;
		input [7:0] orig;
		input [7:0] filt;
		input [3:0] s;
		reg signed [15:0] d;
		begin
			d = $signed({8'd0, filt}) - $signed({8'd0, orig});
			d = (d * $signed({12'd0, s})) >>> 3;
			mix8 = clamp8($signed({8'd0, orig}) + d);
		end
	endfunction

	//-------------------------------------------------------------------------
	// 1. 第一遍 3x3 亮度窗口
	//-------------------------------------------------------------------------
	wire         w_tvalid, w_tuser, w_tlast;
	wire [2:0]   w_rowmask;
	wire [143:0] w_winA, w_winB, w_winC;
	wire [127:0] w_rgb;

	wire [15:0] nw16 = {3'd0, (i_h_active >> 2)};

	preproc_win3x3_rgb #(
		.PX_PER_CLK (PX_PER_CLK)
	) u_win1 (
		.clk       (clk),
		.rst_n     (rst_n),
		.I_nw      (nw16),
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

	wire [143:0] eA = w_rowmask[2] ? w_winA : w_winC;
	wire [143:0] eB = w_rowmask[1] ? w_winB : w_winC;
	wire [143:0] eC = w_winC;

	// 亮度统一用 BT.601, 从**对齐后的原始 RGB** 算 (与直方图/查表一致)
	wire [7:0] c_l0 = lum_sel(w_rgb[23:16], w_rgb[15:8], w_rgb[7:0], 1'b0);
	wire [7:0] c_l1 = lum_sel(w_rgb[55:48], w_rgb[47:40], w_rgb[39:32], 1'b0);
	wire [7:0] c_l2 = lum_sel(w_rgb[87:80], w_rgb[79:72], w_rgb[71:64], 1'b0);
	wire [7:0] c_l3 = lum_sel(w_rgb[119:112], w_rgb[111:104], w_rgb[103:96], 1'b0);

	//-------------------------------------------------------------------------
	// 2. 直方图统计 (4 bank 轮转, 每拍 1 个 lane)
	//-------------------------------------------------------------------------
	reg [23:0] hist0 [0:255];
	reg [23:0] hist1 [0:255];
	reg [23:0] hist2 [0:255];
	reg [23:0] hist3 [0:255];

	// ★ 直方图必须用与 LUT 查表同一个亮度定义 —— LUT 的读地址是 c_l*(= win3x3 内部
	//   固定的 BT.601 亮度)。之前这里用了可配置的 i_gray_mode(默认 BT.709),
	//   而查表用的是 BT.601 -> 统计的分布和查表的索引不是同一个量,
	//   直方图均衡结果自然“不对”, 高强度时幅度差被放大成噪点。
	wire [7:0] in_l0 = lum_sel(i_rgb[23:16], i_rgb[15:8], i_rgb[7:0], 1'b0);
	wire [7:0] in_l1 = lum_sel(i_rgb[55:48], i_rgb[47:40], i_rgb[39:32], 1'b0);
	wire [7:0] in_l2 = lum_sel(i_rgb[87:80], i_rgb[79:72], i_rgb[71:64], 1'b0);
	wire [7:0] in_l3 = lum_sel(i_rgb[119:112], i_rgb[111:104], i_rgb[103:96], 1'b0);

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
	// 上一帧的 LUT（只做时间平滑用，四个 bank 内容相同，只存一份）
	reg [7:0] lutp [0:255];
	reg [7:0] lqp;

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
	                 S_INIT = 3'd6;

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

	// 直方图桶上限(对比度限制): 平坡场景(背景占大多数像素)时,
	// 不做限制会让 CDF 在该桶后垂直跳变 -> 把传感器噪声硬拉伸成噪点。
	// 上限 = i_he_clip * 64 (总数≈2M / 256 桶 ≈ 8192 = 128*64), 0 = 不限制。
	wire [25:0] hclip_v  = {18'd0, i_he_clip, 6'b0};
	wire [25:0] hsum_use = (i_he_clip == 8'd0) ? hsum_now :
	                       ((hsum_now > hclip_v) ? hclip_v : hsum_now);

	wire [7:0] raddr = ((st == S_SUM) || (st == S_LUT)) ? bin : hsel_lum;

	wire [25:0] cdf_n    = cdf + hsum_use;
	wire [25:0] cdfmin_n = (cdf == 26'd0 && hsum_use != 26'd0) ? cdf_n : cdfmin;
	wire [25:0] cdf2_n   = cdf2 + hsum_use;
	wire [25:0] lut_rel  = (cdf2_n >= cdfmin) ? (cdf2_n - cdfmin) : 26'd0;
	wire [51:0] lut_prod = lut_rel * scale + 52'd2048;   // +0.5 四舍五入
	wire [25:0] lut_div  = lut_prod >> 12;
	wire [7:0]  lutv_n   = (lut_div > 26'd255) ? 8'hFF : lut_div[7:0];

	//---------------------------------------------------------------------
	// LUT 斜率限制 + 帧间 IIR (固定参数, 不再给用户开关)
	//
	//   频闪/噪点的真正根因(仿真实测): CDF 的局部斜率 = 该 bin 的计数。
	//   计数小的 bin 会让 LUT 一级跳几十级 -> 传感器 ±1 的噪声被放大几十倍;
	//   而计数本身逐帧统计抖动 -> LUT 逐帧跳变 -> 画面频闪。
	//   实测: 静止场景 + 每帧不同噪声, 1024x? 全帧 2048/2048 像素逐帧变化,
	//   最大帧间差 222 (几乎黑白翻转), 而 LUT 校验和完全不变 —— 证明是
	//   “陡峤 LUT 放大噪声”, 不是 LUT 在跳。
	//
	//   两道闸:
	//     1) 斜率上限 LUT_SLOPE: 每级输入最多升 LUT_SLOPE 级输出,
	//        把噪声放大倍数硬限在 LUT_SLOPE 倍以内; 同时保证 LUT 单调。
	//     2) 帧间 IIR 1/4: new = (cur + 3*prev)/4, 抑制残余逐帧抖动。
	//   两个凸组合都保单调、保斜率上限, 所以写进 LUT 的值始终满足约束。
	//---------------------------------------------------------------------
	localparam [8:0] LUT_SLOPE = P_SLOPE;

	reg  [8:0] lut_last;                // 上一个 bin 实际写入的 LUT 值

	// ⚠ 顺序必须是 IIR 在前、限斜率在后。
	//   如果先限斜率再 IIR, 上一帧的陡坡会以 3/4 的权重透过 lqp 传回来,
	//   斜率限制形同虚设 —— 仿真实测 maxslope 仍然是 8。
	//   现顺序: t_raw = (n + 3*prev)/4, 然后 t = clamp(t_raw, last, last+3)。
	//   这样"写进 LUT 的值"本身一定单调且斜率 ≤ LUT_SLOPE, 与上一帧无关。
	wire [11:0] lutv_mix = P_IIR ? ({4'd0, lutv_n} + {2'd0, lqp, 1'b0} + {3'd0, lqp})
	                            : {4'd0, lutv_n};
	wire [8:0]  lutv_m9  = P_IIR ? ((lutv_mix + 12'd2) >> 2) : lutv_mix[8:0];
	wire [8:0]  lut_lo9  = (P_SLOPE == 9'd0) ? 9'd0 : lut_last;
	wire [8:0]  lut_hi9  = (P_SLOPE == 9'd0) ? 9'd511 : (lut_last + LUT_SLOPE);
	wire [8:0]  lutv_t9  = (lutv_m9 < lut_lo9) ? lut_lo9 :
	                       (lutv_m9 > lut_hi9) ? lut_hi9 : lutv_m9;
	wire [7:0]  lutv_t   = (lutv_t9 > 9'd255) ? 8'hFF : lutv_t9[7:0];

	//-------------------------------------------------------------------------
	// 5. 分帧: 按像素组计数 (不能用 tlast —— ISP 的 tlast 是帧尾脉冲)
	//-------------------------------------------------------------------------
	reg [12:0] grp_cnt;
	reg [11:0] row_cnt;
	reg        build_req;

	wire [12:0] nw = i_h_active >> 2;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			grp_cnt   <= 13'd0;
			row_cnt   <= 12'd0;
			build_req <= 1'b0;
		end else begin
			build_req <= 1'b0;
			if (i_tvalid && (nw != 13'd0) && (i_v_active != 12'd0)) begin
				if ((grp_cnt + 13'd1) >= nw) begin
					grp_cnt <= 13'd0;
					if ((row_cnt + 12'd1) >= i_v_active) begin
						row_cnt   <= 12'd0;
						build_req <= 1'b1;
					end else begin
						row_cnt <= row_cnt + 12'd1;
					end
				end else begin
					grp_cnt <= grp_cnt + 13'd1;
				end
			end
		end
	end

	//-------------------------------------------------------------------------
	// 6. 直方图 RAM (读口 + 写口同一 always 块)
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
	// 7. LUT RAM (读口给像素路径, 写口给状态机)
	//-------------------------------------------------------------------------
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			lq0 <= 8'd0; lq1 <= 8'd0; lq2 <= 8'd0; lq3 <= 8'd0;
		end else begin
			lq0 <= lut0[c_l0];
			lq1 <= lut1[c_l1];
			lq2 <= lut2[c_l2];
			lq3 <= lut3[c_l3];
			lqp <= lutp[raddr];

			if (st == S_INIT) begin
				lut0[bin] <= bin;
				lut1[bin] <= bin;
				lut2[bin] <= bin;
				lut3[bin] <= bin;
				lutp[bin] <= bin;
			end else if ((st == S_LUT) && phase) begin
				lut0[bin] <= lutv_t;
				lut1[bin] <= lutv_t;
				lut2[bin] <= lutv_t;
				lut3[bin] <= lutv_t;
				lutp[bin] <= lutv_t;
			end
		end
	end

	//-------------------------------------------------------------------------
	// 8. 构建 FSM
	//-------------------------------------------------------------------------
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			st       <= S_INIT;
			wait_cnt <= 6'd0;
			bin      <= 8'd0;
			phase    <= 1'b0;
			cdf      <= 26'd0;
			cdfmin   <= 26'd0;
			total    <= 26'd0;
			cdf2     <= 26'd0;
			scale    <= 25'd0;
			lutv     <= 8'd0;
			lut_last <= 9'd0;
			dv_i     <= 6'd0;
			dv_n     <= 32'd0;
			dv_r     <= 32'd0;
			dv_q     <= 32'd0;
			nx_r     <= 32'd0;
			nx_n     <= 32'd0;
			nx_q     <= 32'd0;
		end else begin
			case (st)
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
								st  <= S_CLR;
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
							scale    <= nx_q[24:0];
							st       <= S_LUT;
							bin      <= 8'd0;
							phase    <= 1'b0;
							cdf2     <= 26'd0;
							lut_last <= 9'd0;      // bin0 从 0 开始限制斜率
						end
					end
				end

				S_LUT: begin
					if (!phase) begin
						phase <= 1'b1;
					end else begin
						cdf2     <= cdf2_n;
						lutv     <= lutv_n;
						lut_last <= {1'b0, lutv_t};   // 本 bin 实际写入值 = 下一个 bin 的斜率基准
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
	// 9. 高斯第 1 遍: R / G / B **各自独立** 3x3 二项式 [1 2 1]/4
	//    (只滤亮度再把差值加到 RGB 会把 R/G 的噪声注进 B —— 仿真实测 B 通道
	//     方差 88->109, 这就是"强度越高噪点越重"的根因)
	//-------------------------------------------------------------------------
	wire [95:0] p1_pack;                // 每像素 {R,G,B}

	genvar j, c;
	generate
	for (j = 0; j < 4; j = j + 1) begin : g_p1
		for (c = 0; c < 3; c = c + 1) begin : g_p1c
			wire [7:0] a0 = eA[(24*j)     + 8*c +: 8];
			wire [7:0] a1 = eA[(24*(j+1)) + 8*c +: 8];
			wire [7:0] a2 = eA[(24*(j+2)) + 8*c +: 8];
			wire [7:0] b0 = eB[(24*j)     + 8*c +: 8];
			wire [7:0] b1 = eB[(24*(j+1)) + 8*c +: 8];
			wire [7:0] b2 = eB[(24*(j+2)) + 8*c +: 8];
			wire [7:0] c0 = eC[(24*j)     + 8*c +: 8];
			wire [7:0] c1 = eC[(24*(j+1)) + 8*c +: 8];
			wire [7:0] c2 = eC[(24*(j+2)) + 8*c +: 8];

			wire [11:0] gsum = {4'b0, a0} + {3'b0, a1, 1'b0} + {4'b0, a2}
			                 + {3'b0, b0, 1'b0} + {2'b0, b1, 2'b0} + {3'b0, b2, 1'b0}
			                 + {4'b0, c0} + {3'b0, c1, 1'b0} + {4'b0, c2};
			assign p1_pack[(24*j) + 8*c +: 8] = (gsum + 12'd8) >> 4;   // 四舍五入
		end
	end
	endgenerate

	// 第 2 遍的输入流 (128bit: 每 lane {8'h00,R,G,B})
	wire [127:0] g1_rgb = {
		{8'h00, p1_pack[95:88], p1_pack[87:80],  p1_pack[79:72]},
		{8'h00, p1_pack[71:64], p1_pack[63:56],  p1_pack[55:48]},
		{8'h00, p1_pack[47:40], p1_pack[39:32],  p1_pack[31:24]},
		{8'h00, p1_pack[23:16], p1_pack[15:8],   p1_pack[7:0]}
	};

	wire         w2_tvalid, w2_tuser, w2_tlast;
	wire [2:0]   w2_rowmask;
	wire [143:0] w2_winA, w2_winB, w2_winC;
	wire [127:0] w2_rgb;

	preproc_win3x3_rgb #(
		.PX_PER_CLK (PX_PER_CLK)
	) u_win2 (
		.clk       (clk),
		.rst_n     (rst_n),
		.I_nw      (nw16),
		.i_tvalid  (w_tvalid),
		.i_tuser   (w_tuser),
		.i_tlast   (w_tlast),
		.i_rgb     (g1_rgb),
		.o_tvalid  (w2_tvalid),
		.o_tuser   (w2_tuser),
		.o_tlast   (w2_tlast),
		.o_rowmask (w2_rowmask),
		.o_winA    (w2_winA),
		.o_winB    (w2_winB),
		.o_winC    (w2_winC),
		.o_rgb     (w2_rgb)
	);

	//-------------------------------------------------------------------------
	// 10. 第 2 遍 3x3 (w2 窗口, 已在上面的 u_win2 给出)
	//-------------------------------------------------------------------------
	wire [143:0] f2A = w2_rowmask[2] ? w2_winA : w2_winC;
	wire [143:0] f2B = w2_rowmask[1] ? w2_winB : w2_winC;
	wire [143:0] f2C = w2_winC;

	wire [95:0] p2_pack;

	generate
	for (j = 0; j < 4; j = j + 1) begin : g_p2
		for (c = 0; c < 3; c = c + 1) begin : g_p2c
			wire [7:0] a0 = f2A[(24*j)     + 8*c +: 8];
			wire [7:0] a1 = f2A[(24*(j+1)) + 8*c +: 8];
			wire [7:0] a2 = f2A[(24*(j+2)) + 8*c +: 8];
			wire [7:0] b0 = f2B[(24*j)     + 8*c +: 8];
			wire [7:0] b1 = f2B[(24*(j+1)) + 8*c +: 8];
			wire [7:0] b2 = f2B[(24*(j+2)) + 8*c +: 8];
			wire [7:0] c0 = f2C[(24*j)     + 8*c +: 8];
			wire [7:0] c1 = f2C[(24*(j+1)) + 8*c +: 8];
			wire [7:0] c2 = f2C[(24*(j+2)) + 8*c +: 8];

			wire [11:0] gsum2 = {4'b0, a0} + {3'b0, a1, 1'b0} + {4'b0, a2}
			                  + {3'b0, b0, 1'b0} + {2'b0, b1, 2'b0} + {3'b0, b2, 1'b0}
			                  + {4'b0, c0} + {3'b0, c1, 1'b0} + {4'b0, c2};
			assign p2_pack[(24*j) + 8*c +: 8] = (gsum2 + 12'd8) >> 4;
		end
	end
	endgenerate

	//-------------------------------------------------------------------------
	// 10b. 第 3 遍 3x3 —— 级联 3 遍 3x3 二项式 = 7x7 二项式核
	//      (二项式 [1 2 1] 卷 3 次 = [1 6 15 20 15 6 1], 与高斯 sigma≈1.24 等价)
	//      硬件恒在跑; 选 3x3/5x5 时只取前 1/2 遍的结果, 不影响"并行实现"。
	//-------------------------------------------------------------------------
	wire [127:0] g2_rgb = {
		{8'h00, p2_pack[95:88], p2_pack[87:80], p2_pack[79:72]},
		{8'h00, p2_pack[71:64], p2_pack[63:56], p2_pack[55:48]},
		{8'h00, p2_pack[47:40], p2_pack[39:32], p2_pack[31:24]},
		{8'h00, p2_pack[23:16], p2_pack[15:8],  p2_pack[7:0]}
	};

	wire         w3_tvalid, w3_tuser, w3_tlast;
	wire [2:0]   w3_rowmask;
	wire [143:0] w3_winA, w3_winB, w3_winC;
	wire [127:0] w3_rgb;

	preproc_win3x3_rgb #(
		.PX_PER_CLK (PX_PER_CLK)
	) u_win3 (
		.clk       (clk),
		.rst_n     (rst_n),
		.I_nw      (nw16),
		.i_tvalid  (w2_tvalid),
		.i_tuser   (w2_tuser),
		.i_tlast   (w2_tlast),
		.i_rgb     (g2_rgb),
		.o_tvalid  (w3_tvalid),
		.o_tuser   (w3_tuser),
		.o_tlast   (w3_tlast),
		.o_rowmask (w3_rowmask),
		.o_winA    (w3_winA),
		.o_winB    (w3_winB),
		.o_winC    (w3_winC),
		.o_rgb     (w3_rgb)
	);

	wire [143:0] f3A = w3_rowmask[2] ? w3_winA : w3_winC;
	wire [143:0] f3B = w3_rowmask[1] ? w3_winB : w3_winC;
	wire [143:0] f3C = w3_winC;

	wire [95:0] p3_pack;

	generate
	for (j = 0; j < 4; j = j + 1) begin : g_p3
		for (c = 0; c < 3; c = c + 1) begin : g_p3c
			wire [7:0] a0 = f3A[(24*j)     + 8*c +: 8];
			wire [7:0] a1 = f3A[(24*(j+1)) + 8*c +: 8];
			wire [7:0] a2 = f3A[(24*(j+2)) + 8*c +: 8];
			wire [7:0] b0 = f3B[(24*j)     + 8*c +: 8];
			wire [7:0] b1 = f3B[(24*(j+1)) + 8*c +: 8];
			wire [7:0] b2 = f3B[(24*(j+2)) + 8*c +: 8];
			wire [7:0] c0 = f3C[(24*j)     + 8*c +: 8];
			wire [7:0] c1 = f3C[(24*(j+1)) + 8*c +: 8];
			wire [7:0] c2 = f3C[(24*(j+2)) + 8*c +: 8];

			wire [11:0] gsum3 = {4'b0, a0} + {3'b0, a1, 1'b0} + {4'b0, a2}
			                  + {3'b0, b0, 1'b0} + {2'b0, b1, 2'b0} + {3'b0, b2, 1'b0}
			                  + {4'b0, c0} + {3'b0, c1, 1'b0} + {4'b0, c2};
			assign p3_pack[(24*j) + 8*c +: 8] = (gsum3 + 12'd8) >> 4;
		end
	end
	endgenerate

	//-------------------------------------------------------------------------
	// 11. 12 拍对齐: 3 遍窗口各 4 拍, 所以原始数据要延迟 8 拍(相对 w_* 已 +4)
	//-------------------------------------------------------------------------
	reg [127:0] rgb_d1, rgb_d2, rgb_d3, rgb_d4, rgb_d5, rgb_d6, rgb_d7, rgb_d8;
	reg [31:0]  cl_d1,  cl_d2,  cl_d3,  cl_d4,  cl_d5,  cl_d6,  cl_d7,  cl_d8;
	reg [31:0]  lq_d1,  lq_d2,  lq_d3,  lq_d4,  lq_d5,  lq_d6,  lq_d7,  lq_d8;
	reg [95:0]  p1_d1,  p1_d2,  p1_d3,  p1_d4,  p1_d5,  p1_d6,  p1_d7,  p1_d8;
	reg [95:0]  p2_d1,  p2_d2,  p2_d3,  p2_d4;
	reg         v_d1, v_d2, v_d3, v_d4, v_d5, v_d6, v_d7, v_d8;
	reg         u_d1, u_d2, u_d3, u_d4, u_d5, u_d6, u_d7, u_d8;
	reg         t_d1, t_d2, t_d3, t_d4, t_d5, t_d6, t_d7, t_d8;

	wire [31:0] lq_pack = {lq3, lq2, lq1, lq0};
	wire [31:0] cl_pack = {c_l3, c_l2, c_l1, c_l0};
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			rgb_d1 <= 128'd0; rgb_d2 <= 128'd0; rgb_d3 <= 128'd0; rgb_d4 <= 128'd0;
			rgb_d5 <= 128'd0; rgb_d6 <= 128'd0; rgb_d7 <= 128'd0; rgb_d8 <= 128'd0;
			cl_d1 <= 32'd0; cl_d2 <= 32'd0; cl_d3 <= 32'd0; cl_d4 <= 32'd0;
			cl_d5 <= 32'd0; cl_d6 <= 32'd0; cl_d7 <= 32'd0; cl_d8 <= 32'd0;
			lq_d1 <= 32'd0; lq_d2 <= 32'd0; lq_d3 <= 32'd0; lq_d4 <= 32'd0;
			lq_d5 <= 32'd0; lq_d6 <= 32'd0; lq_d7 <= 32'd0; lq_d8 <= 32'd0;
			p1_d1 <= 96'd0; p1_d2 <= 96'd0; p1_d3 <= 96'd0; p1_d4 <= 96'd0;
			p1_d5 <= 96'd0; p1_d6 <= 96'd0; p1_d7 <= 96'd0; p1_d8 <= 96'd0;
			p2_d1 <= 96'd0; p2_d2 <= 96'd0; p2_d3 <= 96'd0; p2_d4 <= 96'd0;
			v_d1 <= 1'b0; v_d2 <= 1'b0; v_d3 <= 1'b0; v_d4 <= 1'b0;
			v_d5 <= 1'b0; v_d6 <= 1'b0; v_d7 <= 1'b0; v_d8 <= 1'b0;
			u_d1 <= 1'b0; u_d2 <= 1'b0; u_d3 <= 1'b0; u_d4 <= 1'b0;
			u_d5 <= 1'b0; u_d6 <= 1'b0; u_d7 <= 1'b0; u_d8 <= 1'b0;
			t_d1 <= 1'b0; t_d2 <= 1'b0; t_d3 <= 1'b0; t_d4 <= 1'b0;
			t_d5 <= 1'b0; t_d6 <= 1'b0; t_d7 <= 1'b0; t_d8 <= 1'b0;
		end else begin
			rgb_d1 <= w_rgb;    rgb_d2 <= rgb_d1; rgb_d3 <= rgb_d2; rgb_d4 <= rgb_d3;
			rgb_d5 <= rgb_d4;   rgb_d6 <= rgb_d5; rgb_d7 <= rgb_d6; rgb_d8 <= rgb_d7;
			cl_d1  <= cl_pack;  cl_d2  <= cl_d1;  cl_d3  <= cl_d2;  cl_d4  <= cl_d3;
			cl_d5  <= cl_d4;    cl_d6  <= cl_d5;  cl_d7  <= cl_d6;  cl_d8  <= cl_d7;
			lq_d1  <= lq_pack;  lq_d2  <= lq_d1;  lq_d3  <= lq_d2;  lq_d4  <= lq_d3;
			lq_d5  <= lq_d4;    lq_d6  <= lq_d5;  lq_d7  <= lq_d6;  lq_d8  <= lq_d7;
			p1_d1  <= p1_pack;  p1_d2  <= p1_d1;  p1_d3  <= p1_d2;  p1_d4  <= p1_d3;
			p1_d5  <= p1_d4;    p1_d6  <= p1_d5;  p1_d7  <= p1_d6;  p1_d8  <= p1_d7;
			p2_d1  <= p2_pack;  p2_d2  <= p2_d1;  p2_d3  <= p2_d2;  p2_d4  <= p2_d3;
			v_d1   <= w_tvalid; v_d2   <= v_d1;   v_d3   <= v_d2;   v_d4   <= v_d3;
			v_d5   <= v_d4;     v_d6   <= v_d5;   v_d7   <= v_d6;   v_d8   <= v_d7;
			u_d1   <= w_tuser;  u_d2   <= u_d1;   u_d3   <= u_d2;   u_d4   <= u_d3;
			u_d5   <= u_d4;     u_d6   <= u_d5;   u_d7   <= u_d6;   u_d8   <= u_d7;
			t_d1   <= w_tlast;  t_d2   <= t_d1;   t_d3   <= t_d2;   t_d4   <= t_d3;
			t_d5   <= t_d4;     t_d6   <= t_d5;   t_d7   <= t_d6;   t_d8   <= t_d7;
		end
	end


	//-------------------------------------------------------------------------
	// 12. Stage B: 高斯混合(可选核) + 直方图均衡
	//     · 核尺寸: 0=3x3(第1遍) 1=5x5(第2遍) 2=7x7(第3遍)
	//     · 强度是**纯混合系数**: 0=原图 8=完全用滤波结果 (单调, 不会过冲)
	//-------------------------------------------------------------------------
	wire [127:0] rgb_b;
	wire [31:0]  lum_b;

	generate
	for (j = 0; j < 4; j = j + 1) begin : g_blend
		wire [7:0]  cl  = cl_d8[(8*j) +: 8];      // 原始亮度 (BT.601, 与直方图同定义)
		wire [7:0]  lqv = lq_d8[(8*j) +: 8];      // HE LUT 查表结果

		// 三遍滤波结果(每像素 {R,G,B})与原图都在同一拍
		wire [7:0] f1_r = p1_d8[(24*j) + 16 +: 8];
		wire [7:0] f1_g = p1_d8[(24*j) +  8 +: 8];
		wire [7:0] f1_b = p1_d8[(24*j)      +: 8];
		wire [7:0] f2_r = p2_d4[(24*j) + 16 +: 8];
		wire [7:0] f2_g = p2_d4[(24*j) +  8 +: 8];
		wire [7:0] f2_b = p2_d4[(24*j)      +: 8];
		wire [7:0] f3_r = p3_pack[(24*j) + 16 +: 8];
		wire [7:0] f3_g = p3_pack[(24*j) +  8 +: 8];
		wire [7:0] f3_b = p3_pack[(24*j)      +: 8];

		wire [7:0] rp = rgb_d8[(32*j) + 16 +: 8];
		wire [7:0] gp = rgb_d8[(32*j) +  8 +: 8];
		wire [7:0] bp = rgb_d8[(32*j)      +: 8];

		wire [7:0] pr = (i_gauss_ker == 2'd0) ? f1_r :
		                (i_gauss_ker == 2'd1) ? f2_r : f3_r;
		wire [7:0] pg = (i_gauss_ker == 2'd0) ? f1_g :
		                (i_gauss_ker == 2'd1) ? f2_g : f3_g;
		wire [7:0] pb = (i_gauss_ker == 2'd0) ? f1_b :
		                (i_gauss_ker == 2'd1) ? f2_b : f3_b;

		// 逐通道混合 (0=原图, 8=完全用滤波结果)
		wire [7:0] rg = i_en[1] ? mix8(rp, pr, i_gauss_str) : rp;
		wire [7:0] gg = i_en[1] ? mix8(gp, pg, i_gauss_str) : gp;
		wire [7:0] bg = i_en[1] ? mix8(bp, pb, i_gauss_str) : bp;

		// ---- 直方图均衡 (在原亮度上查表, 差值加到当前 RGB) ----
		wire [8:0]  he_inv = 9'd256 - {1'b0, i_he_str};
		wire [16:0] hblend = lqv * i_he_str + cl * he_inv + 17'd128;
		wire [7:0]  hv = hblend[15:8];
		wire signed [15:0] hd = $signed({8'd0, hv}) - $signed({8'd0, cl});

		wire [7:0] rr2 = i_en[2] ? clamp8($signed({8'd0, rg}) + hd) : rg;
		wire [7:0] gg2 = i_en[2] ? clamp8($signed({8'd0, gg}) + hd) : gg;
		wire [7:0] bb2 = i_en[2] ? clamp8($signed({8'd0, bg}) + hd) : bg;

		assign rgb_b[(32*j) +: 32] = {8'h00, rr2, gg2, bb2};
		assign lum_b[(8*j)   +: 8] = lum_sel(rr2, gg2, bb2, i_gray_mode);
	end
	endgenerate

	// 未使用信号占位 (保留便于波形观察)
	wire unused_ok = &{1'b0, w2_rgb[0], w2_tvalid, w2_tuser, w2_tlast,
	                   w3_rgb[0], w3_tvalid, w3_tuser, w3_tlast};

	reg         vb, ub, tb;
	reg [127:0] rgb_s;
	reg [31:0]  lum_s;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			vb <= 1'b0; ub <= 1'b0; tb <= 1'b0;
			rgb_s <= 128'd0;
			lum_s <= 32'd0;
		end else begin
			vb    <= v_d8;
			ub    <= u_d8;
			tb    <= t_d8;
			rgb_s <= rgb_b;
			lum_s <= lum_b;
		end
	end

	//-------------------------------------------------------------------------
	// 12. Stage C: 灰度 / 对比度 / 反色 -> 输出
	//-------------------------------------------------------------------------
	wire [127:0] final_pix;

	generate
	for (j = 0; j < 4; j = j + 1) begin : g_out
		wire [7:0] l  = lum_s[(8*j) +: 8];
		wire [7:0] rp = rgb_s[(32*j) + 16 +: 8];
		wire [7:0] gp = rgb_s[(32*j) +  8 +: 8];
		wire [7:0] bp = rgb_s[(32*j)      +: 8];

		wire [7:0] r3 = i_en[0] ? l : rp;
		wire [7:0] g3 = i_en[0] ? l : gp;
		wire [7:0] b3 = i_en[0] ? l : bp;

		wire [7:0] r4 = i_en[3] ? contrast8(r3, i_contrast) : r3;
		wire [7:0] g4 = i_en[3] ? contrast8(g3, i_contrast) : g3;
		wire [7:0] b4 = i_en[3] ? contrast8(b3, i_contrast) : b3;

// 2026-10-27: 反色(bit4) 已删除 —— 不在赛题硬指标(高斯/直方图/灰度/对比度拉伸)
	//   里。i_en[4] 保留但不再使用, 写 1 不会反色也不会报错。
	wire [7:0] r5 = r4;
	wire [7:0] g5 = g4;
	wire [7:0] b5 = b4;

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
			o_tvalid <= vb;
			o_tuser  <= ub;
			o_tlast  <= tb;
			o_rgb    <= final_pix;
		end
	end

endmodule
