//=============================================================================
//  tb_lineorder.v —— 摸清"行首 16 像素"到底是哪来的内容
//
//  激励: 第 L 行所有像素 = 10 + L (每行一个常量, 灰度, R=G=B),
//        行与行之间插入 GAP 个空闲拍(模拟行消隐)。
//  输出: 打印第 3 帧每行输出的前 12 个、后 4 个像素值 —— 常量值能直接告诉我们
//        "这个像素属于哪一行", 从而确定错位的确切形式。
//=============================================================================
`timescale 1ns / 1ps

module tb_lineorder;

	parameter integer GAP   = 20;
	parameter integer W     = 32;
	parameter integer LINES = 8;
	localparam integer NW = W / 4;

	reg clk = 1'b0;
	always #5 clk = ~clk;

	reg         rst_n = 1'b0;
	reg         tvalid = 1'b0;
	reg         tuser = 1'b0;
	reg         tlast = 1'b0;
	reg [127:0] rgb = 128'd0;

	wire         o_tvalid, o_tuser, o_tlast;
	wire [127:0] o_rgb;

	preproc_basic #(.PX_PER_CLK(4)) u_dut (
		.clk (clk), .rst_n (rst_n),
		.i_h_active (W[12:0]), .i_v_active (LINES[11:0]),
		.i_tvalid (tvalid), .i_tuser (tuser), .i_tlast (tlast), .i_rgb (rgb),
		.i_en (5'b00010), .i_gray_mode (1'b0),
		.i_gauss_str (4'd8), .i_gauss_ker (2'd1),
		.i_he_str (8'd255), .i_he_clip (8'd255), .i_he_temp (4'd2),
		.i_contrast (4'd4),
		.o_tvalid (o_tvalid), .o_tuser (o_tuser), .o_tlast (o_tlast), .o_rgb (o_rgb)
	);

	integer frame, line, w, k, g;
	reg [7:0] pv;

	initial begin
		repeat (5) @(posedge clk);
		rst_n = 1'b1;
		repeat (2) @(posedge clk);
		for (frame = 0; frame < 3; frame = frame + 1) begin
			for (line = 0; line < LINES; line = line + 1) begin
				for (w = 0; w < NW; w = w + 1) begin
					@(negedge clk);
					pv = 10 + line + 40*frame;      // 每行一个常量
					rgb = {4{{8'h00, pv, pv, pv}}};
					tvalid = 1'b1;
					tuser  = (frame == 0 && line == 0 && w == 0);
					tlast  = (w == NW - 1);
				end
				for (g = 0; g < GAP; g = g + 1) begin
					@(negedge clk);
					tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;
				end
			end
		end
		@(negedge clk);
		tvalid = 1'b0;
		repeat (64) @(posedge clk);
		$display("DONE");
		$finish;
	end

	//-------------------------------------------------------------------------
	// 打印: 第 2 帧(oframe==1) 的每行, 前 12 个和后 4 个输出像素
	//-------------------------------------------------------------------------
	integer oframe = 0, col = 0, shown = 0;
	reg [7:0] v;

	always @(posedge clk) begin
		if (rst_n && o_tvalid) begin
			if (o_tuser) begin oframe <= oframe + 1; col <= 0; end
			else if (o_tlast) col <= 0;
			else col <= col + 1;

			v = o_rgb[15:8];
			if (oframe == 1 && col < 12)
				$display("LINE%0d head%0d = %3d", shown, col, v);
			if (oframe == 1 && col >= W - 4)
				$display("LINE%0d tail%0d = %3d", shown, col - (W - 4), v);
			if (oframe == 1 && col == W - 1) shown <= shown + 1;
		end
	end

endmodule
