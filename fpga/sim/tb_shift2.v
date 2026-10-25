//=============================================================================
//  tb_shift2.v —— 同时测**水平与垂直**像素位移（tb_shift 只能测水平，是盲区）
//
//  图案：一个 20 列 x 1 行的矩形亮块（col 90..109, row 4, 值 200，其余 0）。
//    对称核模糊后，亮块的亮度重心在水平和垂直方向都应保持在 (99.5, 4.0)。
//    水平重心 - 99.5 = 水平位移；垂直重心 - 4.0 = 垂直位移（单位：像素）。
//
//  一次仿真跑 8 帧，每帧换一个配置；抓整帧（LINES x W）后在 $finish 前统一算重心。
//    frame 0 : 全关（参考）
//    frame 1 : 高斯 3x3 s8
//    frame 2 : 高斯 5x5 s8
//    frame 3 : 高斯 7x7 s8
//    frame 4 : 中值
//    frame 5 : Sobel g8
//    frame 6 : 拉普拉斯 g8
//    frame 7 : Prewitt g8
//=============================================================================
`timescale 1ns / 1ps

module tb_shift2;

	localparam integer W      = 256;
	localparam integer NW     = W / 4;
	localparam integer LINES  = 12;
	localparam integer C0     = 100;      // 亮块中心列（块宽 20 -> 90..109）
	localparam integer HALF   = 10;
	localparam integer R0     = 6;        // 亮块所在行
	localparam integer VAL    = 200;
	localparam integer GAP    = 6;

	reg clk = 0;
	reg rst_n = 0;
	always #5 clk = ~clk;

	reg          tvalid = 0;
	reg          tuser  = 0;
	reg          tlast  = 0;
	reg  [127:0] rgb    = 0;

	reg [4:0] cfg_en   = 5'd0;
	reg [3:0] cfg_gstr = 4'd8;
	reg [1:0] cfg_gker = 2'd0;
	reg [3:0] cfg_mode = 4'd0;

	//================================================================ DUT A: preproc_basic
	wire         a_tvalid, a_tuser, a_tlast;
	wire [127:0] a_rgb;

	preproc_basic #(.PX_PER_CLK(4)) u_basic (
		.clk(clk), .rst_n(rst_n),
		.i_h_active(W[12:0]), .i_v_active(LINES[11:0]),
		.i_tvalid(tvalid), .i_tuser(tuser), .i_tlast(tlast), .i_rgb(rgb),
		.i_en(cfg_en), .i_gray_mode(1'b0),
		.i_gauss_str(cfg_gstr), .i_gauss_ker(cfg_gker),
		.i_he_str(8'd0), .i_he_clip(8'd8),
		.i_contrast(4'd4),
		.o_tvalid(a_tvalid), .o_tuser(a_tuser), .o_tlast(a_tlast), .o_rgb(a_rgb)
	);

	//================================================================ DUT B: preproc_top
	wire         b_tvalid, b_tuser, b_tlast;
	wire [127:0] b_rgb;

	preproc_top #(.PX_PER_CLK(4)) u_top (
		.clk(clk), .rst_n(rst_n),
		.i_h_active(W[12:0]), .i_v_active(LINES[11:0]),
		.i_tvalid(tvalid), .i_tuser(tuser), .i_tlast(tlast), .i_rgb(rgb),
		.i_basic_en(5'b0), .i_gray_mode(1'b0), .i_gauss_str(4'd0), .i_gauss_ker(2'd0),
		.i_he_str(8'd0), .i_he_clip(8'd8), .i_linefix(1'b0), .i_contrast(4'd4),
		.i_mode(cfg_mode), .i_sobel_gain(5'd8), .i_thresh(8'd32),
		.i_morph_sel(1'b0), .i_morph_th(8'd32), .i_lap_gain(5'd8),
		.i_prew_gain(5'd8), .i_emboss_gain(4'd4), .i_emboss_bias(8'd128),
		.o_tvalid(b_tvalid), .o_tuser(b_tuser), .o_tlast(b_tlast), .o_rgb(b_rgb)
	);

	//================================================================ 图案
	function integer pixv(input integer col, input integer row);
		begin
			pixv = ((col >= C0-HALF) && (col < C0+HALF) && (row == R0)) ? VAL : 0;
		end
	endfunction

	//================================================================ 抓帧（整帧）
	localparam integer FSIZE = LINES * W;
	reg [7:0] bufA [0:8*FSIZE-1];
	reg [7:0] bufB [0:8*FSIZE-1];
	integer wpA, wpB, iA, iB;
	integer f, line, w, k, v, frame;

	always @(posedge clk) begin
		if (rst_n && a_tvalid) begin
			iA = a_tuser ? 0 : wpA;
			bufA[(frame % 8)*FSIZE + iA + 0] <= a_rgb[15:8];
			bufA[(frame % 8)*FSIZE + iA + 1] <= a_rgb[47:40];
			bufA[(frame % 8)*FSIZE + iA + 2] <= a_rgb[79:72];
			bufA[(frame % 8)*FSIZE + iA + 3] <= a_rgb[111:104];
			wpA <= iA + 4;
		end
		if (rst_n && b_tvalid) begin
			iB = b_tuser ? 0 : wpB;
			bufB[(frame % 8)*FSIZE + iB + 0] <= b_rgb[15:8];
			bufB[(frame % 8)*FSIZE + iB + 1] <= b_rgb[47:40];
			bufB[(frame % 8)*FSIZE + iB + 2] <= b_rgb[79:72];
			bufB[(frame % 8)*FSIZE + iB + 3] <= b_rgb[111:104];
			wpB <= iB + 4;
		end
	end

	//================================================================ 激励
	initial begin
		wpA = 0; wpB = 0;
		for (v = 0; v < 8*FSIZE; v = v + 1) begin
			bufA[v] = 8'd0; bufB[v] = 8'd0;
		end
		repeat (8) @(posedge clk);
		rst_n = 1'b1;
		repeat (4) @(posedge clk);

		for (frame = 0; frame < 8; frame = frame + 1) begin
			case (frame)
				0: begin cfg_en = 5'd0;  cfg_gker = 2'd0; cfg_mode = 4'd0; end
				1: begin cfg_en = 5'd2;  cfg_gker = 2'd0; cfg_mode = 4'd0; end
				2: begin cfg_en = 5'd2;  cfg_gker = 2'd1; cfg_mode = 4'd0; end
				3: begin cfg_en = 5'd2;  cfg_gker = 2'd2; cfg_mode = 4'd0; end
				4: begin cfg_en = 5'd0;  cfg_mode = 4'd4; end
				5: begin cfg_en = 5'd0;  cfg_mode = 4'd1; end
				6: begin cfg_en = 5'd0;  cfg_mode = 4'd5; end
				7: begin cfg_en = 5'd0;  cfg_mode = 4'd7; end
			endcase
			repeat (6) @(posedge clk);
			wpA = 0; wpB = 0;

			for (line = 0; line < LINES; line = line + 1) begin
				for (w = 0; w < NW; w = w + 1) begin
					@(negedge clk);
					rgb = 128'd0;
					for (k = 3; k >= 0; k = k - 1) begin
						v = pixv(w*4 + k, line);
						rgb[32*k +: 32] = {8'h00, v[7:0], v[7:0], v[7:0]};
					end
					tvalid = 1'b1;
					tuser  = (line == 0 && w == 0);
					tlast  = (w == NW-1);
				end
				@(negedge clk);
				tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;
				repeat (GAP) @(negedge clk);
			end
			repeat (300) @(negedge clk);
		end
		report;
		$finish;
	end

	//================================================================ 重心
	task calc;                       // 返回 x10 为单位的水平/垂直重心
		input  integer which;        // 0=A 1=B
		input  integer fr;
		output integer cx10;
		output integer cy10;
		output integer tot;
		integer r, c, s, sx, sy, base, px;
		begin
			s = 0; sx = 0; sy = 0;
			for (r = 0; r < LINES; r = r + 1)
				for (c = 0; c < W; c = c + 1) begin
					base = fr*FSIZE + r*W + c;
					px   = (which == 0) ? bufA[base] : bufB[base];
					s  = s  + px;
					sx = sx + c * px;
					sy = sy + r * px;
				end
			tot  = s;
			cx10 = (s == 0) ? -1 : (sx * 10) / s;
			cy10 = (s == 0) ? -1 : (sy * 10) / s;
		end
	endtask

	task report;
		integer fr, cx, cy, tot;
		begin
			$display("");
			$display("亮块 col %0d..%0d  row %0d  值 %0d   （重心应为 x=%0d0  y=%0d0，单位 0.1px）",
			         C0-HALF, C0+HALF-1, R0, VAL, C0, R0);
			$display("---- A: preproc_basic（高斯档位）----");
			for (fr = 0; fr < 4; fr = fr + 1) begin
				calc(0, fr, cx, cy, tot);
				$display("  f%0d  sum=%6d  x=%0d.%0d  y=%0d.%0d   ->  dx=%+0d.%0d  dy=%+0d.%0d px",
				         fr, tot, cx/10, cx%10, cy/10, cy%10,
				         (cx - C0*10)/10, ((cx - C0*10)%10+10)%10,
				         (cy - R0*10)/10, ((cy - R0*10)%10+10)%10);
			end
			$display("---- B: preproc_top（高级层）----");
			for (fr = 0; fr < 8; fr = fr + 1) begin
				calc(1, fr, cx, cy, tot);
				$display("  f%0d  sum=%6d  x=%0d.%0d  y=%0d.%0d   ->  dx=%+0d.%0d  dy=%+0d.%0d px",
				         fr, tot, cx/10, cx%10, cy/10, cy%10,
				         (cx - C0*10)/10, ((cx - C0*10)%10+10)%10,
				         (cy - R0*10)/10, ((cy - R0*10)%10+10)%10);
			end
			// 关键：打印 A 的垂直分布（每行总和），直接看亮块落在哪一行
			$display("---- A 每行亮度总和（亮块应在 row %0d）----", R0);
			for (fr = 0; fr < 4; fr = fr + 1) begin
				$write("  f%0d :", fr);
				for (v = 0; v < LINES; v = v + 1) begin
					calc_row(fr, v, tot);
					$write(" %6d", tot);
				end
				$write("\n");
			end
		end
	endtask

	task calc_row;
		input integer fr;
		input integer r;
		output integer s;
		integer c, base, px;
		begin
			s = 0;
			for (c = 0; c < W; c = c + 1) begin
				base = fr*FSIZE + r*W + c;
				px   = bufA[base];
				s = s + px;
			end
		end
	endtask

endmodule
