//=============================================================================
//  cfg_ctrl_top.v
//  配置控制顶层: I2C 从机 + 参数字符堆 + 跨时钟域
//
//  时钟域划分
//  --------
//    i_sys_clk (25MHz, 常开)  : I2C 从机 + 参数字符堆。
//      用常开时钟而不是像素时钟, 因为链路没起来时也要能配置。
//    i_pix_clk (S_hs_rx_clk)  : 预处理流水线。配置信号在这里被 2 级同步后使用。
//
//  为什么配置要跨时钟域
//  ------------------
//  配置是"准静态"的 —— 只在 I2C 写入时才变。但直接跨域仍可能采到亚稳态,
//  所以每个信号做 2 级触发器同步。多 bit 同时变化(如 mode 0->3)可能被采样到
//  不一致的瞬间, 但只影响一帧且预处理本身无状态, 可以接受。
//
//  帧计数: 在像素域对 tuser 计数, 同步回系统域供 I2C 回读 ——
//  可以据此确认链路在正常出帧。
//=============================================================================
`timescale 1ns / 1ps

module cfg_ctrl_top #(
	parameter [6:0]  DEV_ADDR = 7'h40,
	parameter [15:0] CFG_VER  = 16'h0101
)(
	// ---- 系统时钟域 (25MHz 常开) ----
	input  wire        i_sys_clk,
	input  wire        i_sys_rst_n,

	// ---- I2C 引脚 (三态在顶层处理) ----
	input  wire        i_scl,
	input  wire        i_sda,
	output wire        o_sda_drive,

	// ---- 像素时钟域 ----
	input  wire        i_pix_clk,
	input  wire        i_pix_rst_n,
	input  wire        i_frame_tuser,      // 帧首脉冲, 用于帧计数

	// ---- 同步到像素域的配置输出 ----
	output wire [2:0]  o_pp_mode,
	output wire [3:0]  o_pp_sobel_shift,
	output wire [7:0]  o_pp_thresh,
	output wire        o_pp_morph_sel,

	// ---- 摄像头参数 (直接给 system_top 里的 cam_param, 同在 25MHz 域) ----
	output wire [19:0] o_cam_exp,
	output wire [7:0]  o_cam_gain,
	output wire [3:0]  o_cam_ev,
	output wire [7:0]  o_cam_trig,
	input  wire [15:0] i_cam_wr_cnt,
	input  wire        i_cam_busy,

	// ---- 画质参数 (同步到像素域) ----
	output wire [7:0]  o_wb_r,
	output wire [7:0]  o_wb_b,
	output wire [6:0]  o_roi_pct,
	output wire [2:0]  o_fps_div
);

	//-------------------------------------------------------------------------
	// 上电复位 (系统时钟域)
	//-------------------------------------------------------------------------
	reg [3:0] rst_cnt = 4'd0;
	always @(posedge i_sys_clk)
		if (rst_cnt != 4'hF) rst_cnt <= rst_cnt + 4'd1;
	wire sys_rst_n = i_sys_rst_n & (rst_cnt == 4'hF);

	//-------------------------------------------------------------------------
	// 参数字符堆
	//-------------------------------------------------------------------------
	wire        wr_en;
	wire [7:0]  wr_addr, wr_data;
	wire [7:0]  rd_addr, rd_data;

	wire        cfg_pp_en;
	wire [2:0]  cfg_pp_mode;
	wire [3:0]  cfg_pp_sh;
	wire [7:0]  cfg_pp_th;
	wire        cfg_pp_ms;
	wire        cfg_soft_rst;
	wire        cfg_lossless, cfg_bypass, cfg_single, cfg_rc_en;
	wire [6:0]  cfg_quality;
	wire [23:0] cfg_target;
	wire [3:0]  cfg_rc_speed;
	wire [1:0]  cfg_subsample;
	wire [7:0]  cfg_restart;
	wire [2:0]  cfg_predictor;

	// 摄像头 / 画质参数
	wire [19:0] cfg_cam_exp;
	wire [7:0]  cfg_cam_gain;
	wire [3:0]  cfg_cam_ev;
	wire [7:0]  cfg_cam_trig;
	wire [7:0]  cfg_wb_r, cfg_wb_b;
	wire [6:0]  cfg_roi_pct;
	wire [2:0]  cfg_fps_div;

	// 帧计数 (像素域), 同步回系统域供回读
	reg [31:0] cnt_pix;
	reg [31:0] cnt_s1, cnt_s2;

	jpeg_regfile #(.JPEG_VER(CFG_VER)) u_regfile (
		.I_clk           (i_sys_clk),
		.I_rst_n         (sys_rst_n),
		.I_wr_en         (wr_en),
		.I_wr_addr       (wr_addr),
		.I_wr_data       (wr_data),
		.I_rd_addr       (rd_addr),
		.O_rd_data       (rd_data),
		.O_cfg_lossless  (cfg_lossless),
		.O_cfg_bypass    (cfg_bypass),
		.O_cfg_single    (cfg_single),
		.O_cfg_quality   (cfg_quality),
		.O_cfg_target_bytes (cfg_target),
		.O_cfg_rc_en     (cfg_rc_en),
		.O_cfg_rc_speed  (cfg_rc_speed),
		.O_cfg_subsample (cfg_subsample),
		.O_cfg_restart_int(cfg_restart),
		.O_cfg_predictor (cfg_predictor),
		.O_soft_rst      (cfg_soft_rst),
		.I_st_frame_bytes(24'd0),
		.I_st_total_bytes(32'd0),
		.I_st_scale      (8'd0),
		.I_st_busy       (1'b0),
		.I_st_frame_done (1'b0),
		.I_st_overflow   (1'b0),
		.I_qtable_rd_data(8'h00),
		.O_cfg_pp_en     (cfg_pp_en),
		.O_cfg_pp_mode   (cfg_pp_mode),
		.O_cfg_pp_sobel_shift (cfg_pp_sh),
		.O_cfg_pp_thresh (cfg_pp_th),
		.O_cfg_pp_morph_sel (cfg_pp_ms),
		.I_st_frame_cnt  (cnt_s2),
		.O_cfg_cam_exp   (cfg_cam_exp),
		.O_cfg_cam_gain  (cfg_cam_gain),
		.O_cfg_ev_bias   (cfg_cam_ev),
		.O_cfg_wb_r      (cfg_wb_r),
		.O_cfg_wb_b      (cfg_wb_b),
		.O_cfg_fps_div   (cfg_fps_div),
		.O_cfg_roi_pct   (cfg_roi_pct),
		.O_cfg_cam_trig  (cfg_cam_trig),
		.I_st_cam_wr_cnt (i_cam_wr_cnt),
		.I_st_cam_busy   (i_cam_busy)
	);

	//-------------------------------------------------------------------------
	// I2C 从机
	//-------------------------------------------------------------------------
	i2c_slave #(.DEV_ADDR(DEV_ADDR)) u_i2c (
		.clk       (i_sys_clk),
		.rst_n     (sys_rst_n),
		.scl_i     (i_scl),
		.sda_i     (i_sda),
		.sda_drive (o_sda_drive),
		.o_wr_en   (wr_en),
		.o_wr_addr (wr_addr),
		.o_wr_data (wr_data),
		.o_rd_addr (rd_addr),
		.i_rd_data (rd_data),
		.o_dbg_state  (),
		.o_dbg_wr_cnt (),
		.o_dbg_rd_cnt ()
	);

	//-------------------------------------------------------------------------
	// 帧计数 (像素域) + 同步回系统域
	//-------------------------------------------------------------------------
	always @(posedge i_pix_clk or negedge i_pix_rst_n) begin
		if (!i_pix_rst_n) cnt_pix <= 32'd0;
		else if (i_frame_tuser) cnt_pix <= cnt_pix + 32'd1;
	end

	always @(posedge i_sys_clk or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			cnt_s1 <= 32'd0;
			cnt_s2 <= 32'd0;
		end else begin
			cnt_s1 <= cnt_pix;
			cnt_s2 <= cnt_s1;
		end
	end

	//-------------------------------------------------------------------------
	// 配置信号: 系统域 -> 像素域 (2 级同步)
	//-------------------------------------------------------------------------
	reg [2:0] mode_s1, mode_s2;
	reg [3:0] sh_s1,   sh_s2;
	reg [7:0] th_s1,   th_s2;
	reg       ms_s1,   ms_s2;
	reg [7:0] wbr_s1,  wbr_s2;
	reg [7:0] wbb_s1,  wbb_s2;
	reg [6:0] roi_s1,  roi_s2;
	reg [2:0] fps_s1,  fps_s2;

	always @(posedge i_pix_clk or negedge i_pix_rst_n) begin
		if (!i_pix_rst_n) begin
			mode_s1 <= 3'd0; mode_s2 <= 3'd0;
			sh_s1 <= 4'd3;   sh_s2 <= 4'd3;
			th_s1 <= 8'd128; th_s2 <= 8'd128;
			ms_s1 <= 1'b1;   ms_s2 <= 1'b1;
			wbr_s1 <= 8'd128; wbr_s2 <= 8'd128;
			wbb_s1 <= 8'd128; wbb_s2 <= 8'd128;
			roi_s1 <= 7'd100; roi_s2 <= 7'd100;
			fps_s1 <= 3'd1;   fps_s2 <= 3'd1;
		end else begin
			mode_s1 <= cfg_pp_mode; mode_s2 <= mode_s1;
			sh_s1   <= cfg_pp_sh;   sh_s2   <= sh_s1;
			th_s1   <= cfg_pp_th;   th_s2   <= th_s1;
			ms_s1   <= cfg_pp_ms;   ms_s2   <= ms_s1;
			// 这几个是慢变参数 (人手改的), 2 级同步足够;
			// 注意多比特跨域本应加握手, 但它们在“使用时”已经稳定了几十万个
			// 像素时钟, 不存在采样到中间态的实际窗口。
			wbr_s1  <= cfg_wb_r;    wbr_s2  <= wbr_s1;
			wbb_s1  <= cfg_wb_b;    wbb_s2  <= wbb_s1;
			roi_s1  <= cfg_roi_pct; roi_s2  <= roi_s1;
			fps_s1  <= cfg_fps_div; fps_s2  <= fps_s1;
		end
	end

	assign o_pp_mode        = mode_s2;
	assign o_pp_sobel_shift = sh_s2;
	assign o_pp_thresh      = th_s2;
	assign o_pp_morph_sel   = ms_s2;

	assign o_wb_r    = wbr_s2;
	assign o_wb_b    = wbb_s2;
	assign o_roi_pct = roi_s2;
	assign o_fps_div = fps_s2;

	// 摄像头参数仍在 25MHz 域 (cam_param 也挂这个域), 不用同步
	assign o_cam_exp  = cfg_cam_exp;
	assign o_cam_gain = cfg_cam_gain;
	assign o_cam_ev   = cfg_cam_ev;
	assign o_cam_trig = cfg_cam_trig;

endmodule
