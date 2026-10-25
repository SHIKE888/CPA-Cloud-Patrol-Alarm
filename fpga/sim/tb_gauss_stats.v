//=============================================================================
//  tb_gauss_stats.v —— 高斯滤波噪声抑制量化验证
//
//  目的: 验证 preproc_basic 的高斯滤波在"强度调高时"到底是**降噪**还是**放大噪声**。
//
//  激励: 平坦灰场 128 + 伪随机噪声 (幅度 ±16, 均匀分布), RGB 三通道相同。
//  统计: 取第 4 帧、跳过前 8 行(行缓冲未填满), 统计输出 G 通道的 mean/std,
//        与输入 std 对比。
//
//  用法:
//    iverilog -g2005 -Ptb_gauss_stats.STR=0 -o g.vvp tb_gauss_stats.v \
//             ../uisrc/01_rtl/preproc/preproc_basic.v ../uisrc/01_rtl/preproc/preproc_win3x3.v
//    vvp g.vvp
//=============================================================================
`timescale 1ns / 1ps

module tb_gauss_stats;

	parameter integer STR   = 8;      // 高斯强度 0..8
	parameter integer W     = 32;     // 每行像素数 (必须是 4 的倍数)
	parameter integer LINES = 64;     // 每帧行数
	parameter integer SKIP  = 8;      // 统计时跳过前多少行
	parameter integer COLOR = 0;      // 0=灰场(128,128,128) 1=彩色场(180,100,60)
	parameter integer KER   = 1;      // 0=3x3 1=5x5 2=7x7

	localparam integer NW = W / 4;    // 每行字数

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
		.i_h_active  (W[12:0]),
		.i_v_active  (LINES[11:0]),
		.i_tvalid    (tvalid),
		.i_tuser     (tuser),
		.i_tlast     (tlast),
		.i_rgb       (rgb),
		.i_en        (5'b00010),          // 只开高斯
		.i_gray_mode (1'b0),
		.i_gauss_str (STR[3:0]),
		.i_gauss_ker (KER[1:0]),
		.i_he_str    (8'd255),
		.i_he_clip   (8'd255),
		.i_contrast  (4'd4),
		.o_tvalid    (o_tvalid),
		.o_tuser     (o_tuser),
		.o_tlast     (o_tlast),
		.o_rgb       (o_rgb)
	);

	//-------------------------------------------------------------------------
	// 统计
	//-------------------------------------------------------------------------
	integer oframe = 0;
	integer widx   = 0;
	integer on = 0;
	integer osum [0:3];
	integer osum2[0:3];
	integer in_n = 0;
	integer isum [0:3];
	integer isum2[0:3];
	integer v, ov;
	integer ch;
	reg [7:0] vr, vg, vb;

	initial begin
		for (ch = 0; ch < 3; ch = ch + 1) begin
			osum[ch]  = 0; osum2[ch]  = 0;
			isum[ch]  = 0; isum2[ch]  = 0;
		end
	end

	always @(posedge clk) begin
		if (o_tvalid) begin
			if (o_tuser) begin
				oframe <= oframe + 1;
				widx   <= 0;
			end else begin
				widx <= widx + 1;
			end

			if (oframe == 3 && (widx >> 3) >= SKIP) begin
				on = on + 1;
				for (ch = 0; ch < 3; ch = ch + 1) begin
					ov = o_rgb[8*ch +: 8];
					osum[ch]  = osum[ch]  + ov;
					osum2[ch] = osum2[ch] + ov * ov;
				end
			end
		end
	end

	//-------------------------------------------------------------------------
	// 激励
	//-------------------------------------------------------------------------
	reg [15:0] lfsr = 16'hACE1;
	integer frame, line, w, k;

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
						lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
						v    = ($signed({1'b0, lfsr[4:0]}) - 16);   // -16..+15
						if (COLOR == 0) begin
							vr = v + 128; vg = vr; vb = vr;
						end else if (COLOR == 1) begin
							vr = v + 180; vg = v + 100; vb = v + 60;
						end else begin
							// COLOR=2: 三通道各自独立噪声 (模拟彩色噪点)
							vr = ($signed({1'b0, lfsr[4:0]})   - 16) + 180;
							vg = ($signed({1'b0, lfsr[9:5]})   - 16) + 100;
							vb = ($signed({1'b0, lfsr[14:10]}) - 16) + 60;
						end
						rgb[32*k +: 32] = {8'h00, vr, vg, vb};
						if (frame == 3 && line >= SKIP) begin
							in_n = in_n + 1;
							for (ch = 0; ch < 3; ch = ch + 1) begin
								if (COLOR == 0)      ov = v + 128;
								else if (COLOR == 1) ov = (ch == 0) ? (v + 60) : (ch == 1) ? (v + 100) : (v + 180);
								else                 ov = (ch == 0) ? vb : (ch == 1) ? vg : vr;
								isum[ch]  = isum[ch]  + ov;
								isum2[ch] = isum2[ch] + ov * ov;
							end
						end
					end
					tvalid = 1'b1;
					tuser  = (line == 0 && w == 0);
					tlast  = (w == NW - 1);
				end
			end
		end
		@(negedge clk);
		tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;

		repeat (32) @(posedge clk);

		begin : report
			real im, ivar, om, ovar;
			for (ch = 0; ch < 3; ch = ch + 1) begin
				im   = isum[ch]  * 1.0 / in_n;
				ivar = isum2[ch] * 1.0 / in_n - im * im;
				om   = osum[ch]  * 1.0 / on;
				ovar = osum2[ch] * 1.0 / on - om * om;
				$display("STR=%0d COL=%0d ch=%0d  in(m=%6.2f v=%7.3f)  out(m=%6.2f v=%7.3f)  n=%0d",
				         STR, COLOR, ch, im, ivar, om, ovar, on);
			end
		end
		$display("DONE");
		$finish;
	end

endmodule
