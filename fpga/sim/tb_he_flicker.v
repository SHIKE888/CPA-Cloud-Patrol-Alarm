//=============================================================================
//  tb_he_flicker.v —— 直方图均衡 / 高斯滤波 稳定性实测
//
//  目的(用户诉求): "直方图不应该有防频闪这个功能, 本身就不应该频闪"
//  本 TB 给**逐帧完全相同**的静止输入, 所以输出也应当逐帧完全相同。
//  只要帧间出现差异, 就证明模块自身在制造频闪(与场景变化无关)。
//
//  测试项:
//    T1 只开 HE, LUT 时间平滑关掉(temp=0)
//        -> 每帧输出逐像素比较; 每帧 LUT 校验和; 有效像素期间 FSM 是否还在构建
//    T2 只开 HE, temp=8 (最大平滑) -> 同上, 看平滑能不能掩盖
//    T3 只开高斯 -> 用垂直/水平脉冲图样, 检查滤波核中心是否对齐
//    T4 只开高斯 -> 平坦噪声场, 统计方差(降噪是否生效)
//
//  编译(本机 oss-cad-suite):
//    iverilog -g2005 -o tb_he_flicker.vvp tb_he_flicker.v \
//      ../uisrc/01_rtl/preproc/preproc_basic.v \
//      ../uisrc/01_rtl/preproc/preproc_win3x3_rgb.v
//=============================================================================
`timescale 1ns / 1ps

module tb_he_flicker;

	//------------------------------------------------------------------ 参数
	parameter integer W      = 64;      // 行像素数 (4 的倍数)
	parameter integer LINES  = 32;      // 帧行数
	parameter integer NF     = 14;      // 帧数
	parameter integer GAP    = 2600;    // 帧间消隐拍数 (构建约 1330 拍)
	localparam integer NW    = W / 4;
	localparam integer MAXPX = W * LINES;

	parameter [4:0]  EN     = 5'b00100; // 只开 HE
	parameter [7:0]  HE_STR = 8'd255;
	parameter [7:0]  HE_CLIP= 8'd255;
	parameter [3:0]  G_STR  = 4'd8;
	parameter [1:0]  G_KER  = 2'd1;
	// PAT 运行时可选: +PAT=0/1/2/3 (参数只作默认值)
	parameter integer PAT_DEF = 0;
	integer PAT;

	//------------------------------------------------------------------ 时钟
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
		.i_en        (EN),
		.i_gray_mode (1'b0),
		.i_gauss_str (G_STR),
		.i_gauss_ker (G_KER),
		.i_he_str    (HE_STR),
		.i_he_clip   (HE_CLIP),
		.i_contrast  (4'd4),
		.o_tvalid    (o_tvalid),
		.o_tuser     (o_tuser),
		.o_tlast     (o_tlast),
		.o_rgb       (o_rgb)
	);

	//------------------------------------------------------------------ 图样
	// PAT=0: 窄梯度直方图 (96..159) + 固定伪噪声
	// PAT=1: 全 128, 只在中心一个像素=255 (脉冲响应)
	// PAT=2: 平坦 128 + 固定伪噪声 (降噪测试)
	// PAT=3: 平坦 128 + **每帧不同**的伪噪声 (模拟真实传感器噪声)
	integer cur_frame = 0;
	integer ign_ps;

	function integer pxv;
		input integer x;
		input integer y;
		integer n;
		begin
			case (PAT)
			0: begin
				n = ((x * 13 + y * 29) & 7) - 4;      // 固定 -4..+3
				pxv = 96 + ((x * 3 + y * 7) & 63) + n;
			end
			1: begin
				pxv = (x == 20 && y == 16) ? 255 : 128;
			end
			6: begin
				pxv = (x < 32) ? 40 : 216;            // 垂直阶跃，用来看边缘/重影
			end
			default: begin
				n = ((x * 13 + y * 29) & 31) - 16;    // 固定 -16..+15
				if (PAT == 3)
					n = ((x * 13 + y * 29 + cur_frame * 101) & 31) - 16;
				pxv = 128 + n;
			end
			endcase
		end
	endfunction

	//------------------------------------------------------------------ 输出收集
	reg [7:0] fbuf [0:NF*MAXPX-1];
	integer   fbn  [0:NF-1];
	integer   curf;
	integer   curp;
	integer   i, f, k, r;
	integer   frame, line, w, v;

	// 每帧 LUT 校验和 + 直方图校验和
	integer lutsum [0:NF-1];
	integer histsum[0:NF-1];
	reg [7:0] lutsnap [0:NF*256-1];

	// 有效像素期间 FSM 还在 S_IDLE 之外的拍数 (说明构建侵入了有效区)
	integer fsm_in_valid;
	// LUT 在有效像素期间被改写的次数
	integer lut_wr_in_valid;

	initial begin
		curf = -1;
		curp = 0;
		fsm_in_valid   = 0;
		lut_wr_in_valid = 0;
		for (f = 0; f < NF; f = f + 1) begin
			fbn[f]      = 0;
			lutsum[f]   = 0;
			histsum[f]  = 0;
		end
	end

	always @(posedge clk) begin
		if (o_tvalid) begin
			if (o_tuser) begin
				curf = curf + 1;
				curp = 0;
			end
			if (curf >= 0 && curf < NF && curp < (MAXPX/4)) begin
				for (k = 0; k < 4; k = k + 1)
					fbuf[curf*MAXPX + curp*4 + k] = o_rgb[32*k + 16 +: 8];
				fbn[curf] = fbn[curf] + 4;
			end
			curp = curp + 1;
		end
	end

	// FSM 侵入有效区诊断
	always @(posedge clk) begin		if (tvalid && rst_n && (u_dut.st != 3'd0)) begin			fsm_in_valid = fsm_in_valid + 1;
		end
		if (tvalid && rst_n && (u_dut.st == 3'd4) && u_dut.phase) begin
			lut_wr_in_valid = lut_wr_in_valid + 1;
		end
	end

	//------------------------------------------------------------------ 激励

	initial begin
		ign_ps = $value$plusargs("PAT=%d", PAT);
		repeat (5) @(posedge clk);
		rst_n = 1'b1;
		repeat (5) @(posedge clk);

		for (frame = 0; frame < NF; frame = frame + 1) begin
			cur_frame = frame;
			for (line = 0; line < LINES; line = line + 1) begin
				for (w = 0; w < NW; w = w + 1) begin
					@(negedge clk);
					rgb = 128'd0;
					for (k = 3; k >= 0; k = k - 1) begin
						v = pxv(w*4 + k, line);
						if (v < 0)   v = 0;
						if (v > 255) v = 255;
						// 三通道同值 -> BT.601 亮度恒等于 v, 无舍入误差
						rgb[32*k +: 32] = {8'h00, v[7:0], v[7:0], v[7:0]};
					end
					tvalid = 1'b1;
					tuser  = (line == 0 && w == 0);
					tlast  = (line == LINES-1 && w == NW-1);
				end
			end
			@(negedge clk);
			tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0;
			repeat (GAP) @(posedge clk);
			// 帧尾构建完成后拍下 LUT 快照
			for (i = 0; i < 256; i = i + 1)
				lutsnap[frame*256 + i] = u_dut.lut0[i];
		end

		// 收集每帧 LUT / 直方图校验和
		for (f = 0; f < NF; f = f + 1) begin
			lutsum[f]  = 0;
			histsum[f] = 0;
			for (i = 0; i < 256; i = i + 1) begin
				lutsum[f]  = lutsum[f]  + u_dut.lut0[i];
				histsum[f] = histsum[f] + u_dut.hist0[i];
			end
		end

		// LUT 最大斜率 (斜率大 = 噪声被放大的倍数)
		begin : slope
			integer ms, d, mi;
			for (f = 0; f < NF; f = f + 1) begin
				ms = 0; mi = 0;
				for (i = 1; i < 256; i = i + 1) begin
					d = lutsnap[f*256 + i] - lutsnap[f*256 + i - 1];
					if (d > ms) begin ms = d; mi = i; end
				end
				$display("  frame %0d : maxslope=%0d @bin%0d (%0d->%0d)  lut[0..7]=%0d %0d %0d %0d %0d %0d %0d %0d",
				         f, ms, mi, lutsnap[f*256+mi-1], lutsnap[f*256+mi],
				         lutsnap[f*256+0], lutsnap[f*256+1], lutsnap[f*256+2],
				         lutsnap[f*256+3], lutsnap[f*256+4], lutsnap[f*256+5],
				         lutsnap[f*256+6], lutsnap[f*256+7]);
			end
		end

		$display("==== EN=%b PAT=%0d KER=%0d GSTR=%0d HESTR=%0d CLIP=%0d dut_ker=%0d dut_en=%b W=%0d L=%0d ====",
		         EN, PAT, G_KER, G_STR, HE_STR, HE_CLIP, u_dut.i_gauss_ker, u_dut.i_en, W, LINES);
		for (f = 0; f < NF; f = f + 1)
			$display("  frame %0d : npix=%0d lutsum=%0d histsum=%0d",
			         f, fbn[f], lutsum[f], histsum[f]);

		// 帧间逐像素比较 (帧 1..NF-1 之间应完全相同)
		begin : cmp
			integer nd, maxd, idx, d;
			for (f = 1; f < NF-1; f = f + 1) begin
				nd = 0; maxd = 0;
				for (i = 0; i < MAXPX; i = i + 1) begin
					d = fbuf[(f+1)*MAXPX + i] - fbuf[f*MAXPX + i];
					if (d != 0) begin
						nd = nd + 1;
						if (d < 0) d = -d;
						if (d > maxd) begin maxd = d; idx = i; end
					end
				end
				$display("  DIFF frame %0d vs %0d : ndiff=%0d maxdiff=%0d (at pix %0d: %0d -> %0d)",
				         f, f+1, nd, maxd, idx,
				         fbuf[f*MAXPX + idx], fbuf[(f+1)*MAXPX + idx]);
			end
			// LUT 逐帧抖动（这才是"频闪"的直接来源）
			begin : lutcmp
				integer ln, lmax, ld;
				for (f = 1; f < NF-1; f = f + 1) begin
					ln = 0; lmax = 0;
					for (i = 0; i < 256; i = i + 1) begin
						ld = lutsnap[(f+1)*256 + i] - lutsnap[f*256 + i];
						if (ld != 0) begin
							ln = ln + 1;
							if (ld < 0) ld = -ld;
							if (ld > lmax) lmax = ld;
						end
					end
					$display("  LUT DIFF frame %0d vs %0d : nbins=%0d maxdelta=%0d",
					         f, f+1, ln, lmax);
				end
			end
			// 行首/行尾几个像素（检查换行错位）
			$write("  f1 last row[%0d..] =", MAXPX-8);
			for (i = MAXPX-8; i < MAXPX; i = i + 1) $write(" %0d", fbuf[1*MAXPX + i]);
			$write("\n");
			// 指定行整行打印（脉冲/阶跃定位用）
			for (r = 0; r < LINES; r = r + 1) begin
				if (PAT == 1 ? (r >= 13 && r <= 19) : (r == 16)) begin
					$write("  f2 row%-2d =", r);
					for (i = 0; i < W; i = i + 1) $write(" %0d", fbuf[2*MAXPX + r*W + i]);
					$write("\n");
					$write("  IN  row%-2d =", r);
					for (i = 0; i < W; i = i + 1) $write(" %0d", pxv(i, r));
					$write("\n");
				end
			end
		end

		$display("  fsm_in_valid=%0d  lut_wr_in_valid=%0d", fsm_in_valid, lut_wr_in_valid);
		$display("DONE");
		$finish;
	end

endmodule
