//=============================================================================
//  preproc_win3x3_rgb.v
//  4 像素/时钟 的 **RGB 三通道** 3x3 窗口生成器（高斯滤波专用）
//
//  ── 为什么需要这个模块 ────────────────────────────────────────────────
//  原来的 preproc_win3x3 只跑**亮度**（每个像素存 1 字节），高斯把"亮度差值"
//  同时加到 R/G/B 上。仿真实测（每通道独立噪声，强度 8）：
//      G 通道 方差 88.0 -> 29.1   (被滤掉了)
//      R 通道 方差 87.7 -> 74.6   (只降 15%)
//      B 通道 方差 88.2 -> 109.5  (**反而变大 24%**)
//  原因：亮度里 B 的权重只有 29/256，把"亮度差值"加到 B 上等于把 R/G 的噪声
//  注进 B —— 这就是"高斯强度越高噪点越重"的根因。
//  正确做法：三个通道各自独立滤波。本模块把行缓冲从 32bit/字 改成 96bit/字
//  （4 像素 × 24bit），输出 6 像素 × 3 通道的窗口。
//
//  ── 时序/结构 ─────────────────────────────────────────────────────────
//  与 preproc_win3x3 完全一致（3 拍窗口 + 1 拍输出寄存 = 4 拍延迟），
//  只有"每像素 1 字节"变成"每像素 3 字节"。
//
//  ── 字节序约定（与 preproc_win3x3 相同）────────────────────────────────
//    win[23:0]   = 最左列（上一组第 4 个像素）
//    win[47:24]  = 本组第 1 个像素 ... win[119:96] = 本组第 4 个像素
//    win[143:120]= 最右列（下一组第 1 个像素）
//    每个像素内部 {R,G,B}：bits[23:16]=R, [15:8]=G, [7:0]=B
//=============================================================================
`timescale 1ns / 1ps

module preproc_win3x3_rgb #(
	parameter integer PX_PER_CLK = 4
)(
	input  wire         clk,
	input  wire         rst_n,
	input  wire [15:0]  I_nw,               // 每行字数 (= h_active/4)

	input  wire         i_tvalid,
	input  wire         i_tuser,
	input  wire         i_tlast,
	input  wire [127:0] i_rgb,              // 每 lane {8'h00,R,G,B}

	output reg          o_tvalid,
	output reg          o_tuser,
	output reg          o_tlast,
	output reg  [2:0]   o_rowmask,
	output reg  [143:0] o_winA,             // 上上行 6 像素
	output reg  [143:0] o_winB,             // 上一行
	output reg  [143:0] o_winC,             // 当前行
	output reg  [127:0] o_rgb               // 与窗口对齐的原始 RGB 直通
);

	localparam integer NW = 960;            // 最大字数/行 (4K: 3840/4)
	localparam integer AW = 10;

	//-------------------------------------------------------------------------
	// 1. 128bit(4×{pad,R,G,B}) -> 96bit(4×{R,G,B})
	//-------------------------------------------------------------------------
	wire [95:0] rgb4 = {i_rgb[119:96], i_rgb[87:64], i_rgb[55:32], i_rgb[23:0]};

	//-------------------------------------------------------------------------
	// 2. 两级行缓冲（双口 RAM 读写同地址 = 先读后写，读回的是上一行）
	//-------------------------------------------------------------------------
	reg [95:0] mem1 [0:NW-1];
	reg [95:0] mem2 [0:NW-1];
	reg [AW-1:0] addr, addr_d1;
	reg [95:0] r1_raw, r2_raw;
	reg [11:0] lcnt, lcnt_d1, lcnt_d2, lcnt_d3;

	wire addr_last = (addr == I_nw[AW-1:0] - 1'b1);

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			addr    <= {AW{1'b0}};
			addr_d1 <= {AW{1'b0}};
			r1_raw  <= 96'd0;
			r2_raw  <= 96'd0;
			lcnt    <= 12'd0;
			lcnt_d1 <= 12'd0;
			lcnt_d2 <= 12'd0;
			lcnt_d3 <= 12'd0;
		end else begin
			lcnt_d1 <= lcnt;
			lcnt_d2 <= lcnt_d1;
			lcnt_d3 <= lcnt_d2;

			if (i_tvalid) begin
				mem1[addr]    <= rgb4;
				r1_raw        <= mem1[addr];
				mem2[addr_d1] <= r1_raw;
				r2_raw        <= mem2[addr_d1];

				if (i_tuser) begin
					addr <= {AW{1'b0}};
					lcnt <= 12'd0;
				end else if (addr_last) begin
					addr <= {AW{1'b0}};
					lcnt <= lcnt + 12'd1;
				end else begin
					addr <= addr + 1'b1;
				end
				addr_d1 <= addr;
			end
		end
	end

	//-------------------------------------------------------------------------
	// 3. 三行对齐（当前行去 2 拍、上一行去 1 拍、上上行不去）
	//-------------------------------------------------------------------------
	reg [95:0] cur_d1, cur_d2, r1_d1;
	reg        v_d1, v_d2, u_d1, u_d2, t_d1, t_d2;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			cur_d1 <= 96'd0; cur_d2 <= 96'd0; r1_d1 <= 96'd0;
			v_d1 <= 1'b0; v_d2 <= 1'b0;
			u_d1 <= 1'b0; u_d2 <= 1'b0;
			t_d1 <= 1'b0; t_d2 <= 1'b0;
		end else if (i_tvalid) begin
			// 只有真有像素时才推进（行消隐冻结，避免行首窗口用旧数据）
			cur_d1 <= rgb4;      cur_d2 <= cur_d1;
			r1_d1  <= r1_raw;
			v_d1   <= 1'b1;      v_d2   <= v_d1;
			u_d1   <= i_tuser;   u_d2   <= u_d1;
			t_d1   <= i_tlast;   t_d2   <= t_d1;
		end else begin
			v_d1 <= 1'b0;  v_d2 <= 1'b0;
			u_d1 <= 1'b0;  u_d2 <= 1'b0;
			t_d1 <= 1'b0;  t_d2 <= 1'b0;
		end
	end

	wire [95:0] wA = r2_raw;        // 上上行
	wire [95:0] wB = r1_d1;         // 上一行
	wire [95:0] wC = cur_d2;        // 当前行

	//-------------------------------------------------------------------------
	// 4. 横向窗口：需要"上一组第 4 像素"和"下一组第 1 像素"
	//-------------------------------------------------------------------------
	reg [95:0] a_p1, a_p2, b_p1, b_p2, c_p1, c_p2;
	reg        v_d3, u_d3, t_d3;
	reg [127:0] rgb_d1, rgb_d2, rgb_d3;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			a_p1 <= 96'd0; a_p2 <= 96'd0;
			b_p1 <= 96'd0; b_p2 <= 96'd0;
			c_p1 <= 96'd0; c_p2 <= 96'd0;
			rgb_d1 <= 128'd0; rgb_d2 <= 128'd0; rgb_d3 <= 128'd0;
			v_d3 <= 1'b0; u_d3 <= 1'b0; t_d3 <= 1'b0;
		end else if (v_d2) begin
			a_p1 <= wA;  a_p2 <= a_p1;
			b_p1 <= wB;  b_p2 <= b_p1;
			c_p1 <= wC;  c_p2 <= c_p1;
			rgb_d1 <= i_rgb; rgb_d2 <= rgb_d1; rgb_d3 <= rgb_d2;
			v_d3 <= 1'b1; u_d3 <= u_d2; t_d3 <= t_d2;
		end else begin
			v_d3 <= 1'b0; u_d3 <= 1'b0; t_d3 <= 1'b0;
		end
	end

	// 本拍输出对应"1 拍前那一组"(c_p1)：
	//   前邻 = c_p2 的第 4 像素 [95:72]，后邻 = wC 的第 1 像素 [23:0]
	//   拼接 MSB=最右列, LSB=最左列
	`define WINR(pp, cu, nx) {nx[23:0], cu[95:72], cu[71:48], cu[47:24], cu[23:0], pp[95:72]}

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			o_tvalid  <= 1'b0;
			o_tuser   <= 1'b0;
			o_tlast   <= 1'b0;
			o_rowmask <= 3'b001;
			o_winA    <= 144'd0;
			o_winB    <= 144'd0;
			o_winC    <= 144'd0;
			o_rgb     <= 128'd0;
		end else begin
			o_tvalid  <= v_d3;
			o_tuser   <= u_d3;
			o_tlast   <= t_d3;
			o_winA    <= `WINR(a_p2, a_p1, wA);
			o_winB    <= `WINR(b_p2, b_p1, wB);
			o_winC    <= `WINR(c_p2, c_p1, wC);
			o_rgb     <= rgb_d3;
			o_rowmask <= {(lcnt_d3 >= 12'd2), (lcnt_d3 >= 12'd1), 1'b1};
		end
	end

	`undef WINR

endmodule
