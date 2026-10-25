//=============================================================================
//  preproc_win3x3.v
//  4 像素/时钟 的 3x3 亮度窗口生成器  (预处理流水线 P4/P5/P6 的公共前端)
//
//  输入: ui_isp_top 输出的 RGB888 x4 (128bit, 每个 lane = {8'h00,R,G,B})
//  输出: 对齐好的 3 行 x 6 字节亮度窗口, 供 Sobel / 阈值 / 形态学共用
//
//  ── 为什么要 6 个字节 ─────────────────────────────────────────────────────
//  每时钟到 4 个像素。对第 j 个像素(0..3)做 3x3, 需要列 (j, j+1, j+2) 相对
//  本组的偏移, 于是需要的列跨度是 -1 .. +4, 共 6 个:
//      win[0] = 上一组的第 4 个像素   (左邻, j=0 用)
//      win[1..4] = 本组的 4 个像素
//      win[5] = 下一组的第 1 个像素   (右邻, j=3 用)
//  于是 "像素 j 的 3 列" = win[j], win[j+1], win[j+2]
//
//  ── 行缓冲技巧 ──────────────────────────────────────────────────────────
//  深度只要一行 (480 字), 不是两行:
//  双口 RAM 读地址 == 写地址, 同一时钟"先读后写", 于是读回的是上一次走过
//  这个地址的内容 —— 地址按行循环, 那正好是上一行的同列数据。
//
//  ── 流水线对齐 (靠寄存器链, 不靠"猜") ────────────────────────────────────
//  设 a(n) = 第 n 拍的行内列地址。三个延迟后的信号必须在同一拍对应同一列:
//     去 2 拍: 当前行    lum4_d2   (L   , 列 a(n))
//     去 1 拍: 上一行    r1_d1      (L-1 , 列 a(n))
//     不去  : 上上行      r2_raw     (L-2 , 列 a(n))
//  再经 1 拍横向窗口级, 控制信号总共延迟 3 拍去对齐输出。
//
//  ── 首两行的处理 ────────────────────────────────────────────────────────
//  第 0/1 行的"上一行/上上行"还没被写过(内容是垃圾)。这里用 o_rowmask
//  告诉下游哪几行无效, 由 preproc_edge 用当前行顶替, 保证**帧行数不变**
//  (绝不能丢行 —— 下游按 1080 行解析, 丢行会让色度平面整体错位)。
//=============================================================================
`timescale 1ns / 1ps

module preproc_win3x3 #(
	parameter integer PX_PER_CLK = 4         // 每时钟像素数
)(
	input  wire         clk,
	input  wire         rst_n,
	// V21: 运行时每行字数 (= I_h_active / PX_PER_CLK).
	//  行缓冲数组按 4K 上限固定分配, 运行时用 I_nw 做地址回绕比较,
	//  这样 1080p 与 4K 共用同一套 buffer, 不用重新生成 IP。
	input  wire [15:0]  I_nw,

	// ---- 视频输入 (RGB888x4, 每 lane {8'h00,R,G,B}) ----
	input  wire         i_tvalid,
	input  wire         i_tuser,             // 帧首 (SOF)
	input  wire         i_tlast,
	input  wire [127:0] i_rgb,

	// ---- 3x3 亮度窗口输出 ----
	output reg          o_tvalid,
	output reg          o_tuser,
	output reg          o_tlast,
	output reg  [2:0]   o_rowmask,           // [2]=A(上上行)有效 [1]=B(上一行)有效 [0]=C 恒 1
	output reg  [47:0]  o_winA,              // 上上行 6 字节 {b5..b0}, b0 最左
	output reg  [47:0]  o_winB,              // 上一行
	output reg  [47:0]  o_winC,              // 当前行

	// ---- 与窗口严格对齐的原始 RGB 直通 (供"原图"模式对比) ----
	output reg  [127:0] o_rgb
);

	// V21: 数组按 4K 上限固定分配 (3840/4 = 960 字/行), 运行时由 I_nw 限制实际行宽。
	//      1080p => I_nw = 480; 4K => I_nw = 960。
	localparam integer NW = 960;                     // 最大字数/行
	localparam integer AW = 10;                      // NW=960 需要 10 位

	//-------------------------------------------------------------------------
	// 1. RGB -> 亮度 (BT.601 整数: (77R + 150G + 29B) >> 8, 系数和=256)
	//-------------------------------------------------------------------------
	function [7:0] lum;
		input [7:0] r;
		input [7:0] g;
		input [7:0] b;
		begin
			lum = (77 * r + 150 * g + 29 * b) >> 8;
		end
	endfunction

	wire [7:0] lp0 = lum(i_rgb[23:16], i_rgb[15:8], i_rgb[7:0]);
	wire [7:0] lp1 = lum(i_rgb[55:48], i_rgb[47:40], i_rgb[39:32]);
	wire [7:0] lp2 = lum(i_rgb[87:80], i_rgb[79:72], i_rgb[71:64]);
	wire [7:0] lp3 = lum(i_rgb[119:112], i_rgb[111:104], i_rgb[103:96]);
	wire [31:0] lum4 = {lp3, lp2, lp1, lp0};         // [7:0]=第1个像素

	//-------------------------------------------------------------------------
	// 2. 两级行缓冲 (每级延迟一行)
	//-------------------------------------------------------------------------
	reg [31:0] mem1 [0:NW-1];
	reg [31:0] mem2 [0:NW-1];
	reg [AW-1:0] addr, addr_d1;                      // addr_d1 = addr 延迟 1 拍
	reg [31:0] r1_raw, r2_raw;
	reg [11:0] lcnt, lcnt_d1, lcnt_d2, lcnt_d3;      // 行计数(地址回绕一次 +1)

	wire addr_last = (addr == I_nw[AW-1:0] - 1'b1);

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			addr     <= {AW{1'b0}};
			addr_d1  <= {AW{1'b0}};
			r1_raw   <= 32'd0;
			r2_raw   <= 32'd0;
			lcnt     <= 12'd0;
			lcnt_d1  <= 12'd0;
			lcnt_d2  <= 12'd0;
			lcnt_d3  <= 12'd0;
		end else begin
			lcnt_d1 <= lcnt;
			lcnt_d2 <= lcnt_d1;
			lcnt_d3 <= lcnt_d2;

			if (i_tvalid) begin
				// 行缓冲 1: 写本行, 读同地址 -> 上一行
				mem1[addr]    <= lum4;
				r1_raw        <= mem1[addr];
				// 行缓冲 2: 用延迟 1 拍的地址 (因为 r1_raw 本身晚 1 拍)
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
	// 3. 三级延迟, 把三行对齐到同一列
	//    去 2 拍: 当前行 ; 去 1 拍: 上一行 ; 不去: 上上行
	//-------------------------------------------------------------------------
	reg [31:0] cur_d1, cur_d2;
	reg [31:0] r1_d1;
	reg        v_d1, v_d2;
	reg        u_d1, u_d2;
	reg        t_d1, t_d2;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			cur_d1 <= 32'd0; cur_d2 <= 32'd0; r1_d1 <= 32'd0;
			v_d1 <= 1'b0; v_d2 <= 1'b0;
			u_d1 <= 1'b0; u_d2 <= 1'b0;
			t_d1 <= 1'b0; t_d2 <= 1'b0;
		end else begin
			cur_d1 <= lum4;      cur_d2 <= cur_d1;
			r1_d1  <= r1_raw;
			v_d1   <= i_tvalid;  v_d2   <= v_d1;
			u_d1   <= i_tuser;   u_d2   <= u_d1;
			t_d1   <= i_tlast;   t_d2   <= t_d1;
		end
	end

	wire [31:0] wA = r2_raw;        // 上上行
	wire [31:0] wB = r1_d1;         // 上一行
	wire [31:0] wC = cur_d2;        // 当前行

	//-------------------------------------------------------------------------
	// 4. 横向窗口: 每个 32 位字是 4 个像素, 要凑 6 字节需要
	//    「上一组的第 4 字节」和「下一组的第 1 字节」。
	//    再延迟 1 拍, 于是当前拍同时拥有 前/中/后 三组。
	//-------------------------------------------------------------------------
	reg [31:0] a_p1, a_p2;    // 上上上行组: 1 拍前 / 2 拍前
	reg [31:0] b_p1, b_p2;
	reg [31:0] c_p1, c_p2;
	// ⚠ o_rgb 用 d3: WIN 寄存一级后, 窗口中心 cu=c_p1 的延迟是 3 拍,
	//   像素必须同样 3 拍才与 o_win* 同列。旧版用 d4(=4 拍) 差 1 组(4 像素)。
	reg        v_d3, v_d4, u_d3, u_d4, t_d3, t_d4;
	reg [127:0] rgb_d1, rgb_d2, rgb_d3, rgb_d4;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			a_p1 <= 32'd0; a_p2 <= 32'd0;
			b_p1 <= 32'd0; b_p2 <= 32'd0;
			c_p1 <= 32'd0; c_p2 <= 32'd0;
			rgb_d1 <= 128'd0; rgb_d2 <= 128'd0; rgb_d3 <= 128'd0; rgb_d4 <= 128'd0;
			v_d3 <= 1'b0; v_d4 <= 1'b0;
			u_d3 <= 1'b0; u_d4 <= 1'b0;
			t_d3 <= 1'b0; t_d4 <= 1'b0;
		end else begin
			a_p1 <= wA;  a_p2 <= a_p1;
			b_p1 <= wB;  b_p2 <= b_p1;
			c_p1 <= wC;  c_p2 <= c_p1;
			rgb_d1 <= i_rgb; rgb_d2 <= rgb_d1; rgb_d3 <= rgb_d2; rgb_d4 <= rgb_d3;
			v_d3 <= v_d2; v_d4 <= v_d3;
			u_d3 <= u_d2; u_d4 <= u_d3;
			t_d3 <= t_d2; t_d4 <= t_d3;
		end
	end

	// 本拍输出对应的是「1 拍前那一组」(= c_p1), 它的
	//   前邻 = c_p2[31:24], 后邻 = wC[7:0]
	//
	// ⚠ 字节序约定: **bits[7:0] = 最左列**, bits[47:40] = 最右列。
	//   preproc_edge 里 a0 = win[7:0], a1 = win[15:8] ... 就是按这个约定取的。
	//   拼接时 MSB 在最左, 所以最右列(nx)写在最前, 最左列(pp)写在最后。
	//   (这里曾写反过 —— 现象是窗口数据完全颠倒, Sobel 结果落到错误像素上。)
	`define WIN(pp, cu, nx) {nx[7:0], cu[31:24], cu[23:16], cu[15:8], cu[7:0], pp[31:24]}

	// 行首组左邻钳位到本组(不用上一行最后一组)
	wire [31:0] a_pp = (lcnt_d3 == 12'd0) ? a_p1 : a_p2;
	wire [31:0] b_pp = (lcnt_d3 == 12'd0) ? b_p1 : b_p2;
	wire [31:0] c_pp = (lcnt_d3 == 12'd0) ? c_p1 : c_p2;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			o_tvalid  <= 1'b0;
			o_tuser   <= 1'b0;
			o_tlast   <= 1'b0;
			o_rowmask <= 3'b001;
			o_winA    <= 48'd0;
			o_winB    <= 48'd0;
			o_winC    <= 48'd0;
			o_rgb     <= 128'd0;
		end else begin
			o_tvalid <= v_d3;
			o_tuser  <= u_d3;
			o_tlast  <= t_d3;
			o_winA   <= `WIN(a_pp, a_p1, wA);
			o_winB   <= `WIN(b_pp, b_p1, wB);
			o_winC   <= `WIN(c_pp, c_p1, wC);
			// ⚠ o_rgb 必须与窗口中心(cu=c_p1, 延迟 3)同拍, 不是 d4(延迟 4)。
			//   用 d4 时原图通路过 1 组(4 像素) 领先于窗口,
			//   而高级层只用窗口 -> 整幅画面相对“原图”左移 4 像素。
			o_rgb     <= rgb_d3;
			// lcnt_d3 = 本拍输出这一行(当前行 C)的行号
			o_rowmask <= {(lcnt_d3 >= 12'd2), (lcnt_d3 >= 12'd1), 1'b1};
		end
	end

	`undef WIN

endmodule
