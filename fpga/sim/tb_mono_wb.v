//=============================================================================
//  tb_mono_wb.v —— 单色算子（Sobel/拉普拉斯/Prewitt…）是否被白平衡染色
//
//  现象（用户反馈）：高级预处理选 Sobel / 拉普拉斯 / Prewitt 时，灰度边缘图
//  带红/蓝偏色。
//  原因：preproc_edge 输出的每像素是 {8'h00, gv, gv, gv}（R=G=B），
//        但 preproc_post 的数字白平衡对 R/B 各乘一个增益
//        (R*wb_r, B*wb_b)，立刻把它染成彩色。
//  修法：preproc_post 增加 i_mono，单色算子模式下整段跳过白平衡。
//
//  本 TB 跑两级真实串联：preproc_top(i_mode=1 Sobel) → preproc_post(wb 可调)
//  +MONO=1  期望：所有输出像素 R==G==B，且 ndiff=0
//  +MONO=0  期望：R/G/B 被拉开（对照组，证明白平衡本身在工作）
//=============================================================================
`timescale 1ns / 1ps

module tb_mono_wb;

	localparam integer W        = 64;
	localparam integer LINES    = 6;
	localparam integer NW       = W / 4;
	localparam integer GAP      = 4;
	localparam [7:0]   WB_R     = 8'd200;   // 1.56x，明显不等于 128
	localparam [7:0]   WB_B     = 8'd50;    // 0.39x

	reg clk = 0;
	reg rst_n = 0;
	always #5 clk = ~clk;

	reg          tvalid = 0;
	reg          tuser  = 0;
	reg          tlast  = 0;
	reg  [127:0] rgb    = 0;

	wire         p_tvalid, p_tuser, p_tlast;
	wire [127:0] p_rgb;

	integer MONO;
	integer ign_ps;

	reg i_mode = 4'd1;              // Sobel

	preproc_top #(.PX_PER_CLK(4)) u_top (
		.clk(clk), .rst_n(rst_n),
		.i_h_active(W[12:0]), .i_v_active(LINES[11:0]),
		.i_tvalid(tvalid), .i_tuser(tuser), .i_tlast(tlast), .i_rgb(rgb),
		.i_basic_en(5'b0), .i_gray_mode(1'b0), .i_gauss_str(4'd0), .i_gauss_ker(2'd0),
		.i_he_str(8'd0), .i_he_clip(8'd0), .i_linefix(1'b0), .i_contrast(4'd4),
		.i_mode(i_mode), .i_sobel_gain(5'd4), .i_thresh(8'd128),
		.i_morph_sel(1'b0), .i_morph_th(8'd128), .i_lap_gain(5'd4),
		.i_prew_gain(5'd4), .i_emboss_gain(4'd4), .i_emboss_bias(8'd128),
		.o_tvalid(p_tvalid), .o_tuser(p_tuser), .o_tlast(p_tlast), .o_rgb(p_rgb)
	);

	wire         o_tvalid, o_tuser, o_tlast;
	wire [127:0] o_rgb;

	preproc_post #(.PX_PER_CLK(4)) u_post (
		.clk(clk), .rst_n(rst_n),
		.i_h_active(W[11:0]), .i_v_active(LINES[11:0]),
		.i_tvalid(p_tvalid), .i_tuser(p_tuser), .i_tlast(p_tlast), .i_rgb(p_rgb),
		.i_wb_r(WB_R), .i_wb_b(WB_B), .i_mono(MONO[0]), .i_roi_pct(7'd100),
		.o_tvalid(o_tvalid), .o_tuser(o_tuser), .o_tlast(o_tlast), .o_rgb(o_rgb)
	);

	// 图案: 棋盘 + 渐变，保证 Sobel 有丰富边缘
	function integer pxv(input integer x, input integer y);
		begin
			if (((x >> 3) + (y >> 1)) % 2 == 0) pxv = 40 + ((x * 3) & 63);
			else                               pxv = 190 - ((y * 7) & 63);
		end
	endfunction

	//------------------------------------------------------------- 统计量
	integer npx       = 0;
	integer n_nonmono = 0;
	integer ndiff     = 0;
	integer sample_in = 0, sample_r = 0, sample_g = 0, sample_b = 0;
	integer got_sample = 0;
	integer p;
	reg [7:0] r8, g8, b8;
	reg [127:0] p_rgb_d1;

	integer line, w, k, v;
	initial begin
		MONO = 1;
		ign_ps = $value$plusargs("MONO=%d", MONO);

		repeat (8) @(posedge clk);
		rst_n = 1'b1;
		repeat (4) @(posedge clk);

		for (line = 0; line < LINES; line = line + 1) begin
			for (w = 0; w < NW; w = w + 1) begin
				@(negedge clk);
				rgb = 128'd0;
				for (k = 3; k >= 0; k = k - 1) begin
					v = pxv(w*4 + k, line);
					if (v < 0)   v = 0;
					if (v > 255) v = 255;
					rgb[32*k +: 32] = {8'h00, v[7:0], v[7:0], v[7:0]};
				end
				tvalid = 1'b1;
				tuser  = (line == 0 && w == 0);
				tlast  = (w == NW-1);      // preproc_post 的 ROI 用 tlast 作行尾
			end
			@(negedge clk);
			tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;
			repeat (GAP) @(negedge clk);
		end
		repeat (40) @(negedge clk);

		$display("==== MONO=%0d  wb_r=%0d wb_b=%0d ====", MONO, WB_R, WB_B);
		$display("  npix=%0d  n_nonmono=%0d (R!=G or G!=B)  ndiff_from_input=%0d",
		         npx, n_nonmono, ndiff);
		$display("  sample: in<%0d> -> out R=%0d G=%0d B=%0d",
		         sample_in, sample_r, sample_g, sample_b);
		if (MONO != 0) begin
			if (n_nonmono == 0 && ndiff == 0 && npx > 200)
				$display("PASS: 单色模式下输出严格 R==G==B 且与上游一致（未被白平衡染色）");
			else
				$display("FAIL: 单色模式下仍出现颜色/数值改动");
		end else begin
			if (n_nonmono > 0)
				$display("PASS(对照组): 关闭 i_mono 时白平衡确实把灰度拉开了 -> 说明修复点正确");
			else
				$display("FAIL(对照组): 关掉 i_mono 也没染色，白平衡可能没生效");
		end
		$finish;
	end

	//------------------------------------------------------------- 统计
	always @(posedge clk) begin
		if (rst_n && p_tvalid && p_rgb[23:16] !== 8'h00) begin
			if (!got_sample) begin
				sample_in  = p_rgb[23:16];
				got_sample = 1;
			end
		end
		if (rst_n && o_tvalid) begin
			for (p = 0; p < 4; p = p + 1) begin
				r8 = o_rgb[(32*p) + 16 +: 8];
				g8 = o_rgb[(32*p) +  8 +: 8];
				b8 = o_rgb[(32*p)      +: 8];
				npx = npx + 1;
				if (r8 !== g8 || g8 !== b8) begin
					n_nonmono = n_nonmono + 1;
					if (n_nonmono <= 3)
						$display("  !! non-mono R=%0d G=%0d B=%0d", r8, g8, b8);
				end
			end
			if (sample_r == 0 && o_rgb[23:16] !== 8'h00) begin
				sample_r = o_rgb[23:16];
				sample_g = o_rgb[15:8];
				sample_b = o_rgb[7:0];
			end
		end
	end

	// 与上游逐像素对比（preproc_post 只多 1 拍输出寄存）
	always @(posedge clk) begin
		p_rgb_d1 <= p_rgb;
		if (rst_n && o_tvalid) begin
			for (p = 0; p < 4; p = p + 1) begin
				if (o_rgb[(32*p) +: 24] !== p_rgb_d1[(32*p) +: 24])
					ndiff = ndiff + 1;
			end
		end
	end

endmodule
