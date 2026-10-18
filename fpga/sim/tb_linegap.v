//=============================================================================
//  tb_linegap.v —— 验证"行消隐后行首像素是否被旧数据污染"
//
//  激励: 每行 32 像素的**灰度斜坡**(列 x 的值 = 20 + 3x), 行与行之间插入
//        GAP 个空闲时钟(模拟行消隐)。
//  判据: 第 4 帧、中间行的前 8 个输出像素应≈斜坡值(线性斜坡经平滑后仍是斜坡),
//        若行首出现远离斜坡的值, 说明窗口用了消隐前的旧数据。
//=============================================================================
`timescale 1ns / 1ps

module tb_linegap;

	parameter integer GAP   = 20;     // 行间空闲时钟数
	parameter integer W     = 32;
	parameter integer LINES = 12;
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
		.clk         (clk),
		.rst_n       (rst_n),
		.i_h_active  (W[12:0]),
		.i_v_active  (LINES[11:0]),
		.i_tvalid    (tvalid),
		.i_tuser     (tuser),
		.i_tlast     (tlast),
		.i_rgb       (rgb),
		.i_en        (5'b00010),        // 只开高斯
		.i_gray_mode (1'b0),
		.i_gauss_str (4'd8),
		.i_gauss_ker (2'd1),            // 5x5
		.i_he_str    (8'd255),
		.i_he_clip   (8'd255),
		.i_he_temp   (4'd2),
		.i_contrast  (4'd4),
		.o_tvalid    (o_tvalid),
		.o_tuser     (o_tuser),
		.o_tlast     (o_tlast),
		.o_rgb       (o_rgb)
	);

	//-------------------------------------------------------------------------
	// 激励
	//-------------------------------------------------------------------------
	integer frame, line, w, k, g, x;
	integer oframe = 0;
	integer col = 0;
	integer shown = 0;
	integer nvalid = 0;
	reg [7:0] pv;
	reg [7:0] v;

	initial begin
		repeat (5) @(posedge clk);
		rst_n = 1'b1;
		repeat (2) @(posedge clk);

		for (frame = 0; frame < 4; frame = frame + 1) begin
			for (line = 0; line < LINES; line = line + 1) begin
				for (w = 0; w < NW; w = w + 1) begin
					@(negedge clk);
					rgb = 128'd0;
					for (k = 3; k >= 0; k = k - 1) begin
						x  = 4*w + k;
						pv = 20 + 3*x;                 // 灰度斜坡
						rgb[32*k +: 32] = {8'h00, pv, pv, pv};
					end
					tvalid = 1'b1;
					tuser  = (frame == 0 && line == 0 && w == 0);
					tlast  = (w == NW - 1);
				end
				// 行间空闲 (模拟行消隐)
				for (g = 0; g < GAP; g = g + 1) begin
					@(negedge clk);
					tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;
				end
			end
		end
		@(negedge clk);
		tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;
		repeat (64) @(posedge clk);
		$display("STAT nvalid=%0d oframe=%0d shown=%0d", nvalid, oframe, shown);
		$display("DONE");
		$finish;
	end

	//-------------------------------------------------------------------------
	// 采样: 行首 8 个输出像素与斜坡值比较
	//-------------------------------------------------------------------------
	always @(posedge clk) begin
		if (rst_n && o_tvalid) begin
			nvalid = nvalid + 1;
			if (o_tlast) $display("EOL oframe=%0d col=%0d nvalid=%0d", oframe, col, nvalid);
			if (o_tuser) begin
				oframe <= oframe + 1;
				col    <= 0;
			end else if (o_tlast) begin
				col    <= 0;
			end else begin
				col    <= col + 1;
			end

			if (oframe == 1 && !o_tlast && col < 8 && shown < 6) begin
				v = o_rgb[15:8];
				$display("LINE%d col=%0d out=%3d expect=%3d  %s",
				         shown, col, v, 20 + 3*col,
				         ((v + 10) < (20 + 3*col) || v > (20 + 3*col + 10))
				             ? "  <== 偏离" : "");
			end
			if (oframe == 1 && !o_tlast && col == 7 && shown < 6) begin
				shown <= shown + 1;
			end
		end
	end

endmodule
