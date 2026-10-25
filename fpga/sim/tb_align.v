//=============================================================================
//  tb_align.v —— 验证预处理链（i_basic_en=0, i_mode=0）的像素/标志对齐
//
//  图案: 每行所有像素 = 行号*20 (0,20,40,...)，行间插 3 拍消隐。
//  判定: 输出侧以 o_tuser 为行首，每行前几个像素必须等于**本行**值；
//        若行首出现上一行的值，说明窗口比像素多/少延迟，行首错位。
//
//  这就是板上"每行开头 16 像素是上一行行尾"的可复现实验。
//=============================================================================
`timescale 1ns / 1ps

module tb_align;

	localparam integer CLK_PER  = 6;
	localparam integer NW       = 8;      // 每组 4 像素 -> 32 像素/行
	localparam integer H_ACTIVE = 32;
	localparam integer V_ACTIVE = 6;
	localparam integer GAP      = 3;      // 行消隐拍数

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
		.clk          (clk),
		.rst_n        (rst_n),
		.i_h_active   (H_ACTIVE[12:0]),
		.i_v_active   (V_ACTIVE[11:0]),
		.i_tvalid     (i_tvalid),
		.i_tuser      (i_tuser),
		.i_tlast      (i_tlast),
		.i_rgb        (i_rgb),
		.i_basic_en   (5'b0),
		.i_gray_mode  (1'b0),
		.i_gauss_str  (4'd0),
		.i_gauss_ker  (2'd0),
		.i_he_str     (8'd0),
		.i_he_clip    (8'd0),
		.i_linefix    (1'b0),
		.i_contrast   (4'd4),
		.i_mode       (4'd0),
		.i_sobel_gain (5'd4),
		.i_thresh     (8'd128),
		.i_morph_sel  (1'b0),
		.i_morph_th   (8'd128),
		.i_lap_gain   (5'd4),
		.i_prew_gain  (5'd4),
		.i_emboss_gain(4'd4),
		.i_emboss_bias(8'd128),
		.o_tvalid     (o_tvalid),
		.o_tuser      (o_tuser),
		.o_tlast      (o_tlast),
		.o_rgb        (o_rgb)
	);

	// 每拍 4 像素, R=G=B=v
	function [127:0] pack4(input [7:0] v);
		begin
			pack4 = {8'h00, v, v, v,  8'h00, v, v, v,  8'h00, v, v, v,  8'h00, v, v, v};
		end
	endfunction

	//-------------------------------------------------------------------------
	// 激励
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
				i_tlast  = (r == 0) && (k == 0);   // ui_awb: 帧首脉冲
				i_rgb    = pack4(r * 20);
			end
			@(negedge clk);
			i_tvalid = 1'b0; i_tuser = 1'b0; i_tlast = 1'b0;
			repeat (GAP) @(negedge clk);
		end

		repeat (60) @(negedge clk);
	end

	//-------------------------------------------------------------------------
	// 输出检查
	//-------------------------------------------------------------------------
	integer row_o = -1;
	integer col_o = 0;
	integer bad = 0;
	integer rep_row = -1;
	integer shown = 0;

	always @(posedge clk) begin
		if (rst_n && o_tvalid) begin
			if (o_tuser) begin
				row_o = row_o + 1;
				col_o = 0;
				rep_row = (row_o < 4) ? row_o : -1;
				shown = 0;
			end else begin
				col_o = col_o + 1;
			end

			if (rep_row >= 0 && shown < 3) begin
				$display("OUT row=%0d group=%0d  R=%0d %0d %0d %0d   (expect %0d)",
				         row_o, col_o,
				         o_rgb[23:16], o_rgb[55:48], o_rgb[87:80], o_rgb[119:112],
				         row_o * 20);
				shown = shown + 1;
			end

			if (row_o >= 0 && o_rgb[23:16] !== ((row_o * 20) % 256)) begin
				bad = bad + 1;
				if (bad <= 20)
					$display("  !! BAD row=%0d col=%0d got %0d expect %0d",
					         row_o, col_o, o_rgb[23:16], (row_o*20)%256);
			end
		end
	end

	initial begin
		#(CLK_PER * 4000);
		$display("---- total bad pixels = %0d, out rows = %0d ----", bad, row_o + 1);
		if (bad == 0) $display("PASS: 输出每行像素与本行一致");
		else           $display("FAIL: 行首/行内有跨行像素");
		$finish;
	end

endmodule
