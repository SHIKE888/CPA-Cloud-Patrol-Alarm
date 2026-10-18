//=============================================================================
//  tb_basic.v —— 初级预处理 (preproc_basic) 的算法级验证
//
//  用法: iverilog -g2005 -Ptb_basic.MODE=1 -o tb.vvp tb_basic.v preproc_basic.v preproc_win3x3.v
//        vvp tb.vvp
//    MODE: 1=灰度  2=高斯  3=直方图均衡
//
//  输入图案: 16x4, 每行 4 个字; 左 8 列亮度 64, 右 8 列亮度 192, RGB 相同。
//  第 3 帧取第 2 行的第 1~2 个字 (列 4..11) 打印, 此时 3x3 邻域有效。
//=============================================================================
`timescale 1ns / 1ps

module tb_basic;

	parameter integer MODE = 1;

	reg clk = 1'b0;
	always #5 clk = ~clk;

	reg         rst_n  = 1'b0;
	reg         tvalid = 1'b0;
	reg         tuser  = 1'b0;
	reg         tlast  = 1'b0;
	reg [127:0] rgb    = 128'd0;

	wire         o_tvalid, o_tuser, o_tlast;
	wire [127:0] o_rgb;

	preproc_basic #(.PX_PER_CLK(4)) u_dut (
		.clk         (clk),
		.rst_n       (rst_n),
		.i_h_active  (13'd16),
		.i_v_active  (12'd512),
		.i_tvalid    (tvalid),
		.i_tuser     (tuser),
		.i_tlast     (tlast),
		.i_rgb       (rgb),
		.i_en        (MODE == 1 ? 5'b00001 :
		              MODE == 2 ? 5'b00010 : 5'b00100),
		.i_gray_mode (1'b0),
		.i_gauss_str (4'd8),
		.i_he_str    (8'd255),
		.i_contrast  (4'd4),
		.o_tvalid    (o_tvalid),
		.o_tuser     (o_tuser),
		.o_tlast     (o_tlast),
		.o_rgb       (o_rgb)
	);

	function [31:0] pix;
		input integer col;
		reg [7:0] v;
		begin
			v = (col < 8) ? 8'd64 : 8'd192;
			pix = {8'h00, v, v, v};
		end
	endfunction

	integer frame, line, w, col, idx;
	reg [127:0] word;

	// 采集第 3 帧的输入/输出 (按输出有效拍计)
	integer out_cnt = 0;
	always @(posedge clk) begin
		if (rst_n && o_tvalid) begin
			out_cnt <= out_cnt + 1;
			// 第 2 帧中段 (LUT 已在第 0 帧末尾构建完成)
			if (out_cnt >= 5000 && out_cnt < 5008) begin
				$display("OUT %0d %02h %02h %02h", out_cnt - 5000,
				         o_rgb[23:16], o_rgb[15:8], o_rgb[7:0]);
			end
		end
	end

	initial begin
		repeat (5) @(posedge clk);
		rst_n = 1'b1;
		repeat (2) @(posedge clk);

		for (frame = 0; frame < 3; frame = frame + 1) begin
			for (line = 0; line < 512; line = line + 1) begin
				for (w = 0; w < 4; w = w + 1) begin
					@(negedge clk);
					word = {pix(4*w+3), pix(4*w+2), pix(4*w+1), pix(4*w+0)};
					rgb    = word;
					tvalid = 1'b1;
					tuser  = (line == 0 && w == 0);
					tlast  = (w == 3);
				end
			end
		end
		@(negedge clk);
		tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;

		repeat (16) @(posedge clk);
		$display("DONE mode=%0d", MODE);
		$finish;
	end

endmodule
