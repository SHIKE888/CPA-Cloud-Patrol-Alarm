//=============================================================================
//  tb_win3x3.v —— 单独验证 preproc_win3x3_rgb 的窗口对齐
//  输入: 4 行 x 4 组 (16 像素/行)，像素值 = 行号*100 + 列号，可一眼看出行列
//  打印: 每拍 o_tvalid 时的 o_rgb(中心像素) 与 o_winC 的 6 个像素
//=============================================================================
`timescale 1ns / 1ps

module tb_win3x3;

	localparam integer W  = 64;
	localparam integer NW = W / 4;      // 16 组/行
	localparam integer L  = 6;

	reg clk = 0;
	always #5 clk = ~clk;

	reg          rst_n  = 0;
	reg          tvalid = 0;
	reg          tuser  = 0;
	reg          tlast  = 0;
	reg  [127:0] rgb    = 0;
	wire         o_tvalid, o_tuser, o_tlast;
	wire [2:0]   o_rowmask;
	wire [143:0] o_winA, o_winB, o_winC;
	wire [127:0] o_rgb;

	preproc_win3x3_rgb #(.PX_PER_CLK(4)) u_dut (
		.clk(clk), .rst_n(rst_n),
		.I_nw(NW[15:0]),
		.i_tvalid(tvalid), .i_tuser(tuser), .i_tlast(tlast), .i_rgb(rgb),
		.o_tvalid(o_tvalid), .o_tuser(o_tuser), .o_tlast(o_tlast),
		.o_rowmask(o_rowmask),
		.o_winA(o_winA), .o_winB(o_winB), .o_winC(o_winC), .o_rgb(o_rgb)
	);

	integer line, w, k, v;
	integer nout = 0;

	// 输出打印: 每拍 4 个中心像素 (o_rgb) 与窗口 3 行的 6 像素
	always @(posedge clk) begin
		if (o_tvalid) begin
			$write("OUT#%0d rm=%b rr=%0d rc=%0d ib=%0d wp=%0d rgb=",
			       nout, o_rowmask, u_dut.rrow, u_dut.rcol, u_dut.ib, u_dut.wp);
			for (k = 0; k < 4; k = k + 1) $write(" %3d", o_rgb[32*k + 16 +: 8]);
			$write("  | C:");
			for (k = 0; k < 6; k = k + 1) $write(" %3d", o_winC[24*k + 16 +: 8]);
			$write("  B:");
			for (k = 0; k < 6; k = k + 1) $write(" %3d", o_winB[24*k + 16 +: 8]);
			$write("  A:");
			for (k = 0; k < 6; k = k + 1) $write(" %3d", o_winA[24*k + 16 +: 8]);
			$write("\n");
			nout = nout + 1;
		end
	end

	initial begin
		repeat (4) @(posedge clk);
		rst_n = 1;
		repeat (2) @(posedge clk);

		for (line = 0; line < L; line = line + 1) begin
			for (w = 0; w < NW; w = w + 1) begin
				@(negedge clk);
				rgb = 0;
				for (k = 3; k >= 0; k = k - 1) begin
					v = line * 100 + w * 4 + k;   // 百位=行 个位=列
					rgb[32*k +: 32] = {8'h00, v[7:0], v[7:0], v[7:0]};
				end
				tvalid = 1;
				tuser  = (line == 0 && w == 0);
				tlast  = (w == NW-1);
			end
		end
		@(negedge clk);
		tvalid = 0; tuser = 0; tlast = 0;
		repeat (10) @(posedge clk);
		$display("DONE");
		$finish;
	end

endmodule
