//=============================================================================
//  tb_shift.v —— 测**像素级**横向位移（现有 tb_align* 漏了这一类错误）
//
//  为什么需要它：tb_align* 用逐像素绝对值比对，只能发现"组内重排"，
//  而整幅平移 4/8 像素时，如果图案是周期性的就会被判成 PASS。
//
//  本 TB 用**单像素冲激**（第 100 列 = 200，其余 0）：
//    冲激的"亮度重心"对任何核都应当落在 100 附近（对称核则恰好 100）。
//    输出重心 - 100 = 该配置的像素位移。模糊/边缘/中值都适用。
//
//  一次仿真跑 8 帧，每帧换一个配置：
//    frame 0 : 全关（参考，位移必须是 0）
//    frame 1 : 高斯 3x3 s8
//    frame 2 : 高斯 5x5 s8
//    frame 3 : 高斯 7x7 s8
//    frame 4..7 : 高级模式 i_mode = 4(中值) / 1(Sobel) / 5(拉普拉斯) / 7(Prewitt)
//  两路 DUT 同时喂同一个输入：preproc_basic（测高斯）与 preproc_top（测高级层）。
//=============================================================================
`timescale 1ns / 1ps

module tb_shift;

	localparam integer W      = 256;
	localparam integer NW     = W / 4;
	localparam integer LINES  = 8;
	localparam integer IMPCOL = 100;
	localparam integer IMPHALF = 10;      // 脉冲半宽：col 90..109
	localparam integer IMPVAL = 200;
	localparam integer ROWOUT = 4;
	localparam integer GAP    = 6;

	reg clk = 0;
	reg rst_n = 0;
	always #5 clk = ~clk;

	reg          tvalid = 0;
	reg          tuser  = 0;
	reg          tlast  = 0;
	reg  [127:0] rgb    = 0;

	// ---- config（每帧换）----
	reg [4:0] cfg_en   = 5'd0;
	reg [3:0] cfg_gstr = 4'd8;
	reg [1:0] cfg_gker = 2'd0;
	reg [3:0] cfg_mode = 4'd0;

	//================================================================ DUT A
	wire         a_tvalid, a_tuser, a_tlast;
	wire [127:0] a_rgb;

	preproc_basic #(.PX_PER_CLK(4)) u_basic (
		.clk(clk), .rst_n(rst_n),
		.i_h_active(W[12:0]), .i_v_active(LINES[11:0]),
		.i_tvalid(tvalid), .i_tuser(tuser), .i_tlast(tlast), .i_rgb(rgb),
		.i_en(cfg_en), .i_gray_mode(1'b0),
		.i_gauss_str(cfg_gstr), .i_gauss_ker(cfg_gker),
		.i_he_str(8'd0), .i_he_clip(8'd0),
		.i_contrast(4'd4),
		.o_tvalid(a_tvalid), .o_tuser(a_tuser), .o_tlast(a_tlast), .o_rgb(a_rgb)
	);

	//================================================================ DUT B
	wire         b_tvalid, b_tuser, b_tlast;
	wire [127:0] b_rgb;

	preproc_top #(.PX_PER_CLK(4)) u_top (
		.clk(clk), .rst_n(rst_n),
		.i_h_active(W[12:0]), .i_v_active(LINES[11:0]),
		.i_tvalid(tvalid), .i_tuser(tuser), .i_tlast(tlast), .i_rgb(rgb),
		.i_basic_en(5'b0), .i_gray_mode(1'b0), .i_gauss_str(4'd0), .i_gauss_ker(2'd0),
		.i_he_str(8'd0), .i_he_clip(8'd0), .i_linefix(1'b0), .i_contrast(4'd4),
		.i_mode(cfg_mode), .i_sobel_gain(5'd8), .i_thresh(8'd32),
		.i_morph_sel(1'b0), .i_morph_th(8'd32), .i_lap_gain(5'd8),
		.i_prew_gain(5'd8), .i_emboss_gain(4'd4), .i_emboss_bias(8'd128),
		.o_tvalid(b_tvalid), .o_tuser(b_tuser), .o_tlast(b_tlast), .o_rgb(b_rgb)
	);

	//================================================================ 图案
	function integer pixv(input integer col);
		begin
			pixv = (col >= IMPCOL-IMPHALF && col < IMPCOL+IMPHALF) ? IMPVAL : 0;
		end
	endfunction

	integer f, line, w, k, v;
	integer frame;

	//================================================================ 采样
	// 每帧只采 ROWOUT 这一行的 256 个像素（取 G 通道，单色/彩色都等于亮度）
	integer rowA, rowB, wpA, wpB, idxA, idxB;
	reg [7:0] bufA [0:7*W-1];
	reg [7:0] bufB [0:7*W-1];

	always @(posedge clk) begin
		if (rst_n && a_tvalid) begin
			idxA = a_tuser ? 0 : wpA;
			bufA[(frame % 8)*W + idxA + 0] <= a_rgb[15:8];
			bufA[(frame % 8)*W + idxA + 1] <= a_rgb[47:40];
			bufA[(frame % 8)*W + idxA + 2] <= a_rgb[79:72];
			bufA[(frame % 8)*W + idxA + 3] <= a_rgb[111:104];
			wpA <= idxA + 4;
		end
	end

	always @(posedge clk) begin
		if (rst_n && b_tvalid) begin
			idxB = b_tuser ? 0 : wpB;
			bufB[(frame % 8)*W + idxB + 0] <= b_rgb[15:8];
			bufB[(frame % 8)*W + idxB + 1] <= b_rgb[47:40];
			bufB[(frame % 8)*W + idxB + 2] <= b_rgb[79:72];
			bufB[(frame % 8)*W + idxB + 3] <= b_rgb[111:104];
			wpB <= idxB + 4;
		end
	end

	//================================================================ 激励
	initial begin
		rowA = 0; rowB = 0; wpA = 0; wpB = 0;
		for (v = 0; v < 8*W; v = v + 1) begin
			bufA[v] = 8'hxx; bufB[v] = 8'hxx;
		end
		repeat (8) @(posedge clk);
		rst_n = 1'b1;
		repeat (4) @(posedge clk);

		for (frame = 0; frame < 8; frame = frame + 1) begin
			// 每帧配一个方案
			case (frame)
				0: begin cfg_en = 5'd0;  cfg_gker = 2'd0; cfg_mode = 4'd0; end // 参考
				1: begin cfg_en = 5'd2;  cfg_gker = 2'd0; cfg_mode = 4'd0; end // 3x3
				2: begin cfg_en = 5'd2;  cfg_gker = 2'd1; cfg_mode = 4'd0; end // 5x5
				3: begin cfg_en = 5'd2;  cfg_gker = 2'd2; cfg_mode = 4'd0; end // 7x7
				4: begin cfg_en = 5'd0;  cfg_mode = 4'd4; end                 // 中值
				5: begin cfg_en = 5'd0;  cfg_mode = 4'd1; end                 // Sobel
				6: begin cfg_en = 5'd0;  cfg_mode = 4'd5; end                 // 拉普拉斯
				7: begin cfg_en = 5'd0;  cfg_mode = 4'd7; end                 // Prewitt
			endcase
			repeat (6) @(posedge clk);
			wpA = 0; wpB = 0;

			for (line = 0; line < LINES; line = line + 1) begin
				for (w = 0; w < NW; w = w + 1) begin
					@(negedge clk);
					rgb = 128'd0;
					for (k = 3; k >= 0; k = k - 1) begin
						v = pixv(w*4 + k);
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
	task report;
		integer fr, i, s, sx, c, tot;
		begin
			$display("宽脉冲 col%0d..%0d value=%0d  (重心应 = %0d0, 单位 0.1px)",
			         IMPCOL-IMPHALF, IMPCOL+IMPHALF-1, IMPVAL, IMPCOL);
			$display("---- A: preproc_basic ----");
			for (fr = 0; fr < 4; fr = fr + 1) begin
				s = 0; sx = 0;
				for (i = 8; i < W - 8; i = i + 1) begin
					s  = s  + bufA[fr*W + i];
					sx = sx + i * bufA[fr*W + i];
				end
				c = (s == 0) ? 0 : (sx * 10) / s;
				$display("  A frame%0d  total=%0d  centroid=%0d.%0d px  shift=%0d.%0d px",
				         fr, s, c/10, c%10, (c - IMPCOL*10)/10, ((c - IMPCOL*10)%10 + 10) % 10);
			end
			$display("---- B: preproc_top (mode 4/1/5/7) ----");
			for (fr = 0; fr < 8; fr = fr + 1) begin
				s = 0; sx = 0;
				for (i = 8; i < W - 8; i = i + 1) begin
					s  = s  + bufB[fr*W + i];
					sx = sx + i * bufB[fr*W + i];
				end
				c = (s == 0) ? 0 : (sx * 10) / s;
				$display("  B frame%0d  total=%0d  centroid=%0d.%0d px  shift=%0d.%0d px",
				         fr, s, c/10, c%10, (c - IMPCOL*10)/10, ((c - IMPCOL*10)%10 + 10) % 10);
			end
			// 打印 frame0 的原始行，便于确认图案与对齐
			$write("  A f0 row: ");
			for (i = 92; i < 110; i = i + 1) $write(" %3d", bufA[0*W + i]);
			$write("\n  A f2 row: ");
			for (i = 92; i < 110; i = i + 1) $write(" %3d", bufA[2*W + i]);
			$write("\n  B f5 row: ");
			for (i = 92; i < 110; i = i + 1) $write(" %3d", bufB[5*W + i]);
			$write("\n");
		end
	endtask

endmodule
