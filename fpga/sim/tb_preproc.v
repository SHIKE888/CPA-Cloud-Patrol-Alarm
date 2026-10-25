//=============================================================================
//  tb_preproc.v  —— 预处理流水线仿真 testbench
//
//  两个阶段:
//    Phase A  直接给 preproc_edge 灌 64 组合成 3x3 窗口, 4 种模式同时输出
//             -> 验算法本身 (Sobel / 阈值 / 形态学) 对不对
//    Phase B  把 32 行 x 16 字 的图像流灌进 preproc_top
//             -> 验窗口生成器的**行缓冲对齐**对不对
//
//  数据设计: 让一个 32 位字里 4 个像素亮度全相同且等于 (k & 0xFF),
//            这样窗口长什么样一眼可见, Python 侧模型也极简。
//            (RGB 三通道都填同一个值 -> 亮度 = (77+150+29)*v>>8 = v, 无损)
//
//  输出: 直接 $display 到 stdout, 由 run_preproc.sh 重定向到日志。
//=============================================================================
`timescale 1ns / 1ps

module tb_preproc;

	//------------------------------------------------------------------ 时钟
	reg clk = 1'b0;
	always #5 clk = ~clk;          // 100 MHz

	//------------------------------------------------------------------ 窗口字节生成
	// wb(n, r, i): 第 n 组窗口、第 r 行(0=A 1=B 2=C)、第 i 列(0..5) 的亮度
	function [7:0] wb;
		input integer n;
		input integer r;
		input integer i;
		begin
			wb = (n * 7 + r * 23 + i * 41 + 13) & 32'hFF;
		end
	endfunction

	//================================================================ PHASE A
	reg         rst_n    = 1'b0;
	reg         a_valid  = 1'b0;
	reg [47:0]  a_winA   = 48'd0;
	reg [47:0]  a_winB   = 48'd0;
	reg [47:0]  a_winC   = 48'd0;
	reg [127:0] a_rgb    = 128'd0;
	reg [2:0]   a_rm     = 3'b111;

	wire [127:0] eo0, eo1, eo2, eo3;      // 4 种模式的输出
	wire         ev0, ev1, ev2, ev3;

	preproc_edge u_e0 (
		.clk(clk), .rst_n(rst_n),
		.i_tvalid(a_valid), .i_tuser(1'b0), .i_tlast(1'b0),
		.i_rowmask(a_rm), .i_winA(a_winA), .i_winB(a_winB), .i_winC(a_winC),
		.i_rgb(a_rgb),
		.i_mode(4'd0), .i_sobel_shift(4'd3), .i_thresh(8'd128),
		.i_morph_sel(1'b1), .i_morph_th(8'd128),
		.i_lap_shift(4'd3), .i_prew_shift(4'd3),
		.i_emboss_gain(4'd4), .i_emboss_bias(8'd128),
		.o_tvalid(ev0), .o_tuser(), .o_tlast(), .o_rgb(eo0));

	preproc_edge u_e1 (
		.clk(clk), .rst_n(rst_n),
		.i_tvalid(a_valid), .i_tuser(1'b0), .i_tlast(1'b0),
		.i_rowmask(a_rm), .i_winA(a_winA), .i_winB(a_winB), .i_winC(a_winC),
		.i_rgb(a_rgb),
		.i_mode(4'd1), .i_sobel_shift(4'd3), .i_thresh(8'd128),
		.i_morph_sel(1'b1), .i_morph_th(8'd128),
		.i_lap_shift(4'd3), .i_prew_shift(4'd3),
		.i_emboss_gain(4'd4), .i_emboss_bias(8'd128),
		.o_tvalid(ev1), .o_tuser(), .o_tlast(), .o_rgb(eo1));

	preproc_edge u_e2 (
		.clk(clk), .rst_n(rst_n),
		.i_tvalid(a_valid), .i_tuser(1'b0), .i_tlast(1'b0),
		.i_rowmask(a_rm), .i_winA(a_winA), .i_winB(a_winB), .i_winC(a_winC),
		.i_rgb(a_rgb),
		.i_mode(4'd2), .i_sobel_shift(4'd3), .i_thresh(8'd128),
		.i_morph_sel(1'b1), .i_morph_th(8'd128),
		.i_lap_shift(4'd3), .i_prew_shift(4'd3),
		.i_emboss_gain(4'd4), .i_emboss_bias(8'd128),
		.o_tvalid(ev2), .o_tuser(), .o_tlast(), .o_rgb(eo2));

	preproc_edge u_e3 (
		.clk(clk), .rst_n(rst_n),
		.i_tvalid(a_valid), .i_tuser(1'b0), .i_tlast(1'b0),
		.i_rowmask(a_rm), .i_winA(a_winA), .i_winB(a_winB), .i_winC(a_winC),
		.i_rgb(a_rgb),
		.i_mode(4'd3), .i_sobel_shift(4'd3), .i_thresh(8'd128),
		.i_morph_sel(1'b1), .i_morph_th(8'd128),
		.i_lap_shift(4'd3), .i_prew_shift(4'd3),
		.i_emboss_gain(4'd4), .i_emboss_bias(8'd128),
		.o_tvalid(ev3), .o_tuser(), .o_tlast(), .o_rgb(eo3));

	//================================================================ PHASE B
	localparam integer H_ACTIVE   = 64;
	localparam integer PX_PER_CLK = 4;
	localparam integer NW         = H_ACTIVE / PX_PER_CLK;    // 16
	localparam integer NLINE      = 32;
	localparam integer NWORD      = NW * NLINE;               // 512

	reg         b_valid = 1'b0;
	reg         b_tuser = 1'b0;
	reg         b_tlast = 1'b0;
	reg [127:0] b_rgb   = 128'd0;

	wire         p_tvalid, p_tuser, p_tlast;
	wire [127:0] p_rgb;

	preproc_top #(
		.PX_PER_CLK (PX_PER_CLK)
	) u_dut (
		.clk(clk), .rst_n(rst_n),
		.i_h_active(H_ACTIVE[12:0]),
		.i_v_active(NLINE[11:0]),
		.i_tvalid(b_valid), .i_tuser(b_tuser), .i_tlast(b_tlast), .i_rgb(b_rgb),
		.i_basic_en(5'd0), .i_gray_mode(1'b0), .i_gauss_str(4'd8),
		.i_he_str(8'd255), .i_contrast(4'd4),
		.i_mode(4'd1),           // Sobel
		.i_sobel_shift(4'd3),
		.i_thresh(8'd128),
		.i_morph_sel(1'b1),
		.i_morph_th(8'd128),
		.i_lap_shift(4'd3),
		.i_prew_shift(4'd3),
		.i_emboss_gain(4'd4),
		.i_emboss_bias(8'd128),
		.o_tvalid(p_tvalid), .o_tuser(p_tuser), .o_tlast(p_tlast), .o_rgb(p_rgb));

	// 探针: 把窗口内部信号引出来 (验证行缓冲对齐)
	wire [2:0]  d_rm   = u_dut.u_win.o_rowmask;
	wire [47:0] d_winA = u_dut.u_win.o_winA;
	wire [47:0] d_winB = u_dut.u_win.o_winB;
	wire [47:0] d_winC = u_dut.u_win.o_winC;

	//================================================================ 主流程
	integer n, k, L, c, b;
	reg [31:0] word;

	initial begin
		rst_n = 1'b0;
		repeat (5) @(posedge clk);
		rst_n = 1'b1;
		repeat (2) @(posedge clk);

		// ---------------- Phase A ----------------
		for (n = 0; n < 64; n = n + 1) begin
			@(negedge clk);
			a_winA = {wb(n,0,5), wb(n,0,4), wb(n,0,3), wb(n,0,2), wb(n,0,1), wb(n,0,0)};
			a_winB = {wb(n,1,5), wb(n,1,4), wb(n,1,3), wb(n,1,2), wb(n,1,1), wb(n,1,0)};
			a_winC = {wb(n,2,5), wb(n,2,4), wb(n,2,3), wb(n,2,2), wb(n,2,1), wb(n,2,0)};
			a_rgb  = {32'h00_112233, 32'h00_445566, 32'h00_778899, 32'h00_AABBCC};
			a_valid = 1'b1;
			@(posedge clk);              // 采样点
			#1;                          // 等输出寄存器更新
			$display("A %0d %012h %012h %012h %032h %032h %032h %032h",
			         n, a_winA, a_winB, a_winC, eo0, eo1, eo2, eo3);
		end
		@(negedge clk);
		a_valid = 1'b0;

		// ---------------- Phase B ----------------
		// 复位一次, 清掉行缓冲状态
		@(negedge clk) rst_n = 1'b0;
		repeat (5) @(posedge clk);
		@(negedge clk) rst_n = 1'b1;

		for (k = 0; k < NWORD; k = k + 1) begin
			@(negedge clk);
			word   = k & 32'hFF;                       // 4 个像素亮度都 = k&0xFF
			b_rgb  = {8'h00, word[7:0], word[7:0], word[7:0],
			          8'h00, word[7:0], word[7:0], word[7:0],
			          8'h00, word[7:0], word[7:0], word[7:0],
			          8'h00, word[7:0], word[7:0], word[7:0]};
			b_tuser = (k == 0);
			b_tlast = ((k % NW) == (NW-1));
			b_valid = 1'b1;
		end
		@(negedge clk);
		b_valid = 1'b0;
		b_tuser = 1'b0;
		b_tlast = 1'b0;

		repeat (16) @(posedge clk);
		$display("DONE");
		$finish;
	end

	// Phase B: 每个时钟把输出打出来
	//
	// ⚠ 时序对齐 (踩过坑):
	//   o_winA 是寄存器输出 W(k) (第 k 拍 settle 的值);
	//   而 p_rgb 是 f(W(k-1)) —— preproc_edge 内部还有一级输出寄存, 所以
	//   同一个 posedge 读到的 p_rgb 对应的是**前一拍**的窗口。
	//   直接同拍显示会错位 1 拍: 平滑图上 Sobel 值恰好不变所以看不出来,
	//   只在行边界 255->0 的跳变处暴露 (现象就是边界附近零星不符)。
	//   这里把窗口再延迟一拍, 就与 p_rgb 严格对齐了。
	reg [2:0]  rm_z;
	reg [47:0] wa_z, wb_z, wc_z;
	always @(posedge clk) begin
		rm_z <= d_rm;
		wa_z <= d_winA;
		wb_z <= d_winB;
		wc_z <= d_winC;
	end

	integer m = 0;
	always @(posedge clk) begin
		if (rst_n && p_tvalid) begin
			$display("B %0d %b %b %03b %012h %012h %012h %032h",
			         m, p_tuser, p_tlast, rm_z, wa_z, wb_z, wc_z, p_rgb);
			m = m + 1;
		end
	end

endmodule
