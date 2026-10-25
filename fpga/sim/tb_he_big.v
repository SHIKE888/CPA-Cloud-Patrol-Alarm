`timescale 1ns / 1ps
//=============================================================================
// tb_he_big.v —— 真实尺度 (1920x1080) 下的 HE 帧间稳定性
//
// 为什么需要这个台子:
//   tb_he_flicker.v 只有 512x32 = 2048 个像素, 直方图每桶只有个位数计数,
//   完全没有"大面积平坦背景 -> 少数桶爆满 -> 裁上限起作用"的真实特征,
//   所以它在仿真里始终稳定, 复现不了板上 70 级的亮度摆动。
//
// 这个台子:
//   · 1920x1080, 4 px/clk (与板上完全一致), 1080 行 x 480 组
//   · 峰形直方图: 大片背景 84 + 中灰斜坡 + 高光块  -> 计数集中在少数桶
//   · 每帧独立的逐像素噪声 +/-2 (模拟静止场景的真实噪声)
//   · TB 自己统计一份直方图, 用它算 "HE 之后的整帧均值" —— 就是板上
//     实测从 93.7 摆到 164.2 的那个量
//
// 编译期开关 (A/B 用, 默认值与板上 bit 一致):
//   -D SLOPE=<n>   LUT 每 bin 最大上升级数, 0=关闭斜率限制
//   -D IIR=<0|1>   帧间 1/4 平滑
//   -D VLINES=<n>  行数, 默认 1080 (调小可加速)
//
// 运行:
//   vvp x.vvp +CLIP=8 +NF=8
//=============================================================================
module tb_he_big;

	`ifndef SLOPE
	 `define SLOPE 9'd3
	`endif
	`ifndef IIR
	 `define IIR 1'b0
	`endif
	`ifndef VLINES
	 `define VLINES 1080
	`endif

	localparam H_ACT = 1920;
	localparam V_ACT = `VLINES;
	localparam NW    = H_ACT / 4;      // 480 组/行

	reg clk = 0;
	always #3.366 clk = ~clk;          // 148.5 MHz

	reg rst_n = 0;
	reg        tvalid = 0;
	reg        tuser  = 0;
	reg        tlast  = 0;
	reg [127:0] rgb   = 0;

	wire        o_tvalid, o_tuser, o_tlast;
	wire [127:0] o_rgb;

	reg [7:0] he_clip;
	reg [11:0] vact;        // 送给 DUT 的 i_v_active (可与实际行数不等 —— 帧边界错位实验)

	preproc_basic #(
		.P_SLOPE (`SLOPE),
		.P_IIR   (`IIR)
	) u_dut (
		.clk        (clk),
		.rst_n      (rst_n),
		.i_h_active (H_ACT),
		.i_v_active (vact),
		.i_tvalid   (tvalid),
		.i_tuser    (tuser),
		.i_tlast    (tlast),
		.i_rgb      (rgb),
		.i_en       (5'b00100),      // 只开 HE
		.i_gray_mode(1'b0),
		.i_gauss_str(4'd8),
		.i_gauss_ker(2'd0),
		.i_he_str   (8'd255),
		.i_he_clip  (he_clip),
		.i_contrast (4'd4),
		.o_tvalid   (o_tvalid),
		.o_tuser    (o_tuser),
		.o_tlast    (o_tlast),
		.o_rgb      (o_rgb)
	);

	//------------------------------------------------------------------ 激励
	integer frame, line, w, k, i;
	integer NF     = 8;
	integer CLIP   = 8;
	integer VACT   = 0;
	integer ign_ps;

	// TB 侧独立统计的直方图 (全速率, 每个像素一次)
	integer tbh0[0:255];
	integer tbh1[0:255];
	integer tbh2[0:255];
	integer tbh3[0:255];

	// 上一帧的 LUT 快照
	reg [7:0] ls[0:255];
	integer   fn;
	integer   lum, mean_i;
	integer   lum_sum, npx, lsum;
	integer   hist_i;

	// 场景: 峰形直方图 + 逐像素噪声
	function integer scene;
		input integer x;
		input integer y;
		integer h, v;
		begin
			h = (x + y) & 31;
			if (y < V_ACT/3)
				v = 84 + (h % 5) - 2;              // 大片背景, 集中在 82..86
			else if (y < (2*V_ACT)/3)
				v = 120 + ((x * 41) / H_ACT);      // 中灰斜坡 120..160
			else
				v = 196 + (h % 7) - 3;             // 高光块
			v = v + (({$random} % 5) - 2);         // 逐帧独立噪声 -2..+2
			if (v < 0)   v = 0;
			if (v > 255) v = 255;
			scene = v;
		end
	endfunction

	initial begin
		ign_ps = $value$plusargs("NF=%d",   NF);
		ign_ps = $value$plusargs("CLIP=%d", CLIP);
		ign_ps = $value$plusargs("VACT=%d", VACT);
		he_clip = CLIP[7:0];
		vact   = (VACT == 0) ? V_ACT : VACT[11:0];

		for (i = 0; i < 256; i = i + 1) begin
			tbh0[i] = 0; tbh1[i] = 0; tbh2[i] = 0; tbh3[i] = 0;
		end

		repeat (5) @(posedge clk);
		rst_n = 1'b1;
		repeat (5) @(posedge clk);

		$display("=== tb_he_big  V_ACT=%0d  H_ACT=%0d  i_v_active=%0d  CLIP=%0d  SLOPE=%0d IIR=%0d ===",
		         V_ACT, H_ACT, vact, CLIP, `SLOPE, `IIR);

		for (frame = 0; frame < NF; frame = frame + 1) begin
			for (i = 0; i < 256; i = i + 1) begin
				tbh0[i] = 0; tbh1[i] = 0; tbh2[i] = 0; tbh3[i] = 0;
			end

			for (line = 0; line < V_ACT; line = line + 1) begin
				for (w = 0; w < NW; w = w + 1) begin
					@(negedge clk);
					rgb = 128'd0;
					for (k = 3; k >= 0; k = k - 1) begin
						lum = scene(w*4 + k, line);
						tbh0[lum] = tbh0[lum] + 1;      // TB 侧统计(全速率)
						// 三通道同值 -> BT.601 亮度恒等于 lum
						rgb[32*k +: 32] = {8'h00, lum[7:0], lum[7:0], lum[7:0]};
					end
					tvalid = 1'b1;
					tuser  = (line == 0 && w == 0);
					tlast  = (line == V_ACT-1 && w == NW-1);
					@(posedge clk);
				end
			end

			// 场消隐: 等建表完成 (S_WAIT+S_SUM+S_DIV+S_LUT+S_CLR ~ 1400 拍)
			@(negedge clk);
			tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;
			repeat (4000) @(posedge clk);

			// 输出图像均值 = sum(hist * LUT) / N  (这就是板上摆动的那个量)
			lum_sum = 0; npx = 0; lsum = 0;
			for (i = 0; i < 256; i = i + 1) begin
				lum_sum = lum_sum + tbh0[i] * u_dut.lut0[i];
				npx     = npx     + tbh0[i];
				lsum    = lsum    + u_dut.lut0[i];
			end
			mean_i = (npx != 0) ? (lum_sum / npx) : 0;

			$display("frame %0d : HE后均值=%0d  lutsum=%0d  lut[64]=%0d lut[128]=%0d lut[192]=%0d lut[255]=%0d",
			         frame, mean_i, lsum, u_dut.lut0[64], u_dut.lut0[128],
			         u_dut.lut0[192], u_dut.lut0[255]);
			$fflush;

			for (i = 0; i < 256; i = i + 1) ls[i] = u_dut.lut0[i];
		end
		$finish;
	end

	initial begin
		#50_000_000;
		$display("TIMEOUT");
		$finish;
	end

endmodule
