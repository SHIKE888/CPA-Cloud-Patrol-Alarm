//=============================================================================
//  tb_align3.v —— 参数化：行长 / 初级预处理开关
//
//  图案: 每行所有像素 = 行号*20（行内完全同值）
//  检查:
//    1) 每行 group1..NW-1 的所有像素必须彼此相等 (行内一致, 无残留)
//    2) 行首组 group0 的**最右像素**必须等于本行值
//       (若为上一行值 -> 行首仍被上一行行尾污染)
//
//  用途:
//    - 默认 32 列, BASIC_EN=0  : 基础对齐
//    - BASIC_EN=2 (高斯,强度8) : 验证开算法后行首不串行
//    - H_ACTIVE=3840, V_ACTIVE=2 : 验证 4K 行长(960 组)窗口缓冲不回绕
//=============================================================================
`timescale 1ns / 1ps

module tb_align3;

	parameter integer CLK_PER   = 6;
	parameter integer H_ACTIVE  = 32;
	parameter integer V_ACTIVE  = 4;
	parameter integer BASIC_EN  = 0;
	parameter integer GAUSS_STR = 8;
	parameter integer GAUSS_KER = 0;
	parameter integer HE_STR    = 0;
	parameter integer LINEFIX   = 0;
	parameter integer FRAMES    = 1;
	parameter integer GAP       = 3;
	localparam integer NW  = H_ACTIVE / 4;

	reg clk = 0;
	reg rst_n = 0;
	always #(CLK_PER/2) clk = ~clk;

	reg         i_tvalid = 0;
	reg         i_tuser  = 0;
	reg         i_tlast  = 0;
	reg  [127:0] i_rgb   = 0;

	wire        o_tvalid, o_tuser, o_tlast;
	wire [127:0] o_rgb;

	preproc_top #(.PX_PER_CLK(4)) dut (
		.clk(clk), .rst_n(rst_n),
		.i_h_active(H_ACTIVE[12:0]), .i_v_active(V_ACTIVE[11:0]),
		.i_tvalid(i_tvalid), .i_tuser(i_tuser), .i_tlast(i_tlast), .i_rgb(i_rgb),
		.i_basic_en(BASIC_EN[4:0]), .i_gray_mode(1'b0),
		.i_gauss_str(GAUSS_STR[3:0]), .i_gauss_ker(GAUSS_KER[1:0]),
		.i_he_str(HE_STR[7:0]), .i_he_clip(8'd255), 
		.i_linefix(LINEFIX[0]), .i_contrast(4'd4),
		.i_mode(4'd0), .i_sobel_gain(5'd4), .i_thresh(8'd128),
		.i_morph_sel(1'b0), .i_morph_th(8'd128), .i_lap_gain(5'd4),
		.i_prew_gain(5'd4), .i_emboss_gain(4'd4), .i_emboss_bias(8'd128),
		.o_tvalid(o_tvalid), .o_tuser(o_tuser), .o_tlast(o_tlast), .o_rgb(o_rgb)
	);

	function [127:0] pack4(input [7:0] v);
		begin
			pack4 = {8'h00, v, v, v,  8'h00, v, v, v,  8'h00, v, v, v,  8'h00, v, v, v};
		end
	endfunction

	integer r, k, f;
	initial begin
		rst_n = 0;
		repeat (10) @(posedge clk);
		rst_n = 1;
		repeat (5) @(posedge clk);

		for (f = 0; f < FRAMES; f = f + 1) begin
		for (r = 0; r < V_ACTIVE; r = r + 1) begin
			for (k = 0; k < NW; k = k + 1) begin
				@(negedge clk);
				i_tvalid = 1'b1;
				i_tuser  = (k == 0);
				i_tlast  = (r == 0) && (k == 0);
				i_rgb    = pack4(r * 20);
			end
			@(negedge clk);
			i_tvalid = 1'b0; i_tuser = 1'b0; i_tlast = 1'b0;
			repeat (GAP) @(negedge clk);
		end
		end
		repeat (40) @(negedge clk);
	end

	//-------------------------------------------------------------------------
	integer row_o = -1;
	integer col_o = 0;
	integer bad = 0;
	integer frame_o = 0;
	integer p;
	reg [7:0] ref_v;          // 本行 group1 的第一个像素值(参考)
	reg [7:0] first_v;        // 行首组最右像素

	always @(posedge clk) begin
		if (rst_n && o_tvalid) begin
			if (o_tlast) begin
				frame_o = frame_o + 1;
				row_o   = -1;
				ref_v   = 8'hxx;
				first_v = 8'hxx;
			end
			if (o_tuser) begin
				if (frame_o >= FRAMES - 1 && row_o > 0 && first_v !== ref_v) begin
					bad = bad + 1;
					$display("  !! row=%0d 行首最右像素=%0d, 本行参考=%0d (跨行污染)",
					         row_o - 1, first_v, ref_v);
				end
				row_o = row_o + 1;
				first_v = o_rgb[119:112];     // 本行行首组(group0)的最右像素
				col_o = 0;
				ref_v = 8'hxx;
			end else col_o = col_o + 1;

			if (col_o == 1) ref_v = o_rgb[23:16];
			if (frame_o >= FRAMES - 1 && col_o > 0 && ref_v !== 8'hxx) begin
				for (p = 0; p < 4; p = p + 1)
					if (o_rgb[(32*p) + 16 +: 8] !== ref_v) begin
						bad = bad + 1;
						if (bad <= 10)
							$display("  !! row=%0d group=%0d pix=%0d got=%0d ref=%0d",
							         row_o, col_o, p, o_rgb[(32*p)+16 +: 8], ref_v);
					end
			end
		end
	end

	// 行首组的最右像素在 o_tuser 拍采样(已并入上方 always)

	initial begin
		#(CLK_PER * (FRAMES * V_ACTIVE * (NW + GAP) + 600));
		$display("---- H_ACTIVE=%0d V_ACTIVE=%0d BASIC_EN=%0d KER=%0d FRAMES=%0d ----",
		         H_ACTIVE, V_ACTIVE, BASIC_EN, GAUSS_KER, FRAMES);
		$display("---- bad = %0d, frames = %0d ----", bad, frame_o);
		if (bad == 0 && frame_o >= FRAMES - 1) $display("PASS");
		else                                    $display("FAIL");
		$finish;
	end

endmodule
