//=============================================================================
//  tb_align2.v —— 列渐变图案，逐像素验证预处理链(全关)的列位置
//
//  图案: pix(row,col) = col*8 (0..248, 32 列 x 4 像素/组 = 8 组)
//  判定: 输出每个像素必须等于 本行列号*8。
//        任何 4 像素(1 组)偏移都会立刻暴露。
//=============================================================================
`timescale 1ns / 1ps

module tb_align2;

	localparam integer CLK_PER  = 6;
	localparam integer NW       = 8;
	localparam integer H_ACTIVE = 32;
	localparam integer V_ACTIVE = 4;
	localparam integer GAP      = 3;

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
		.i_basic_en(5'b0), .i_gray_mode(1'b0), .i_gauss_str(4'd0), .i_gauss_ker(2'd0),
		.i_he_str(8'd0), .i_he_clip(8'd0), .i_he_temp(4'd0),
		.i_linefix(1'b0), .i_contrast(4'd4),
		.i_mode(4'd0), .i_sobel_gain(5'd4), .i_thresh(8'd128),
		.i_morph_sel(1'b0), .i_morph_th(8'd128), .i_lap_gain(5'd4),
		.i_prew_gain(5'd4), .i_emboss_gain(4'd4), .i_emboss_bias(8'd128),
		.i_sharp_gain(5'd8),
		.o_tvalid(o_tvalid), .o_tuser(o_tuser), .o_tlast(o_tlast), .o_rgb(o_rgb)
	);

	function [31:0] px(input integer col);
		reg [7:0] v;
		begin
			v   = col * 8;
			px  = {8'h00, v, v, v};
		end
	endfunction

	//-------------------------------------------------------------------------
	integer r, k;
	initial begin
		rst_n = 0;
		repeat (10) @(posedge clk);
		rst_n = 1;
		repeat (5) @(posedge clk);

		for (r = 0; r < V_ACTIVE; r = r + 1) begin
			for (k = 0; k < NW; k = k + 1) begin
				@(negedge clk);
				i_tvalid = 1'b1;
				i_tuser  = (k == 0);
				i_tlast  = (r == 0) && (k == 0);
				i_rgb    = {px(k*4+3), px(k*4+2), px(k*4+1), px(k*4+0)};
			end
			@(negedge clk);
			i_tvalid = 1'b0; i_tuser = 1'b0; i_tlast = 1'b0;
			repeat (GAP) @(negedge clk);
		end
		repeat (40) @(negedge clk);
	end

	//-------------------------------------------------------------------------
	integer row_o = -1;
	integer col_o = 0;
	integer bad = 0;
	integer p;
	reg [7:0] got, exp;

	always @(posedge clk) begin
		if (rst_n && o_tvalid) begin
			if (o_tuser) begin
				row_o = row_o + 1;
				col_o = 0;
				$display("OUT row=%0d start: %0d %0d %0d %0d (expect %0d %0d %0d %0d)",
				         row_o, o_rgb[23:16], o_rgb[55:48], o_rgb[87:80], o_rgb[119:112],
				         0, 8, 16, 24);
			end else col_o = col_o + 1;

			if (row_o >= 0) begin
				for (p = 0; p < 4; p = p + 1) begin
					got = o_rgb[(32*p) + 16 +: 8];
					exp = ((col_o * 4 + p) * 8) % 256;
					if (got !== exp) begin
						bad = bad + 1;
						if (bad <= 20)
							$display("  !! row=%0d group=%0d pix=%0d got=%0d expect=%0d",
							         row_o, col_o, p, got, exp);
					end
				end
			end
		end
	end

	initial begin
		#(CLK_PER * 4000);
		$display("---- bad pixels = %0d, rows = %0d ----", bad, row_o + 1);
		if (bad == 0) $display("PASS: 逐像素列位置完全一致");
		else          $display("FAIL: 存在像素/组偏移");
		$finish;
	end

endmodule
