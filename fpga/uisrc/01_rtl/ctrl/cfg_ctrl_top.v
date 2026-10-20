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
	//=========================================================================
	// CFG_VER: 本 bit 流的构建版本号, 可通过 I2C 寄存器 0xA9(低)/0xAA(高) 读出。
	//   ★ 每次要烧到板上的构建都把这个号 +1, 否则无法确认板子上跑的是哪一版。
	//   (2026-10-17 就吃过一次亏: 改完 VMAX 以为烧了, 实测数据全是旧 bit 的,
	//    白分析了一轮"VMAX 不生效")
	//   编码: 高字节 = 大版本(hex), 低字节 = 该版本内的构建序号
	//     0x3504 = V35 第 4 次构建 (V35d: 4K VMAX=2788 想拿 25fps)
	//     0x4301 = V43 第 1 次构建 (修 4K 每行多 1~2 个 word 导致的斜向撕裂)
	//=========================================================================
	parameter [15:0] CFG_VER  = 16'h4507
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
	input  wire        i_frame_tuser,      // (旧) ISP 输出帧首 — 实测恒为 0, 仅保留端口
	// V36 诊断: 真正能用的帧首信号 (都在 i_pix_clk 域)
	input  wire        i_fs_csi,           // CSI-2 FS 短包 -> 传感器真实帧率
	input  wire        i_fs_corr,          // ui_image_correction 输出帧首
	input  wire        i_last_corr,        // ui_image_correction 行尾
	// V21 诊断: 一行的像素组数 (来自 i_pix_clk 域)
	input  wire [15:0] i_line_groups,

	// 2026-10-20: LP-free RX 调试总线 (i_pix_clk 域, 内部 2 级同步到 i_sys_clk)
	input  wire [7:0]  i_dbg_mipi,
	input  wire [7:0]  i_dbg_delay,
	input  wire [5:0]  i_dbg_best_len,
	input  wire        i_dbg_autodone,

	// ---- 同步到像素域的配置输出 ----
	output wire [3:0]  o_pp_mode,          // 高级单选 0..8
	output wire [4:0]  o_pp_sobel_gain,
	output wire [7:0]  o_pp_thresh,
	output wire        o_pp_morph_sel,
	output wire [7:0]  o_pp_morph_th,
	output wire [4:0]  o_pp_lap_gain,
	output wire [4:0]  o_pp_prew_gain,
	output wire [3:0]  o_pp_emboss_gain,
	output wire [7:0]  o_pp_emboss_bias,
	output wire [4:0]  o_pp_sharp_gain,
	// 初级预处理 (V45, 多选位图)
	output wire [4:0]  o_basic_en,
	output wire        o_basic_gray,
	output wire [3:0]  o_basic_gauss,
	output wire [1:0]  o_basic_ker,
	output wire [7:0]  o_basic_he,
	output wire [7:0]  o_basic_he_clip,
	output wire [3:0]  o_basic_he_temp,
	output wire        o_basic_linefix,
	output wire [3:0]  o_basic_contrast,

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
	output wire [2:0]  o_fps_div,
	// V21: 分辨率模式 (0=1080p60 默认, 1=4K30) + 变更脉冲
	output wire [1:0]  o_res_mode,
	output wire        o_res_chg,
	// 2026-10-21: CSI RX 手动 tap 步进按钮 (idle=1, 写 0xD9 产生一次按下->释放)
	output wire        o_dbg_btn,
	// 2026-10-21: Bayer 相位 (0=RGGB 1=GRBG 2=GBRG 3=BGGR), 已同步到像素域
	output wire [1:0]  o_bayer_sel
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
	wire [3:0]  cfg_pp_mode;
	wire [4:0]  cfg_pp_sh;
	wire [7:0]  cfg_pp_th;
	wire        cfg_pp_ms;
	wire [7:0]  cfg_pp_morph_th;
	wire [4:0]  cfg_pp_lap_sh;
	wire [4:0]  cfg_pp_prew_sh;
	wire [3:0]  cfg_pp_emboss_gain;
	wire [7:0]  cfg_pp_emboss_bias;
	wire [4:0]  cfg_pp_sharp_gain;
	wire [4:0]  cfg_basic_en;
	wire        cfg_basic_gray;
	wire [3:0]  cfg_basic_gauss;
	wire [1:0]  cfg_basic_ker;
	wire [7:0]  cfg_basic_he;
	wire [7:0]  cfg_basic_he_clip;
	wire [3:0]  cfg_basic_he_temp;
	wire        cfg_basic_linefix;
	wire [3:0]  cfg_basic_contrast;
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
	wire [1:0]  cfg_bayer_sel;
	wire [6:0]  cfg_roi_pct;
	wire [2:0]  cfg_fps_div;
	reg  [15:0] lg_s1, lg_s2;   // V21 诊断同步器
	reg  [15:0] lg_max;         // V21 诊断: 历史最大行组数
	wire [1:0]  cfg_res_mode;   // V21
	wire        cfg_res_chg;    // V21

	// 帧计数 (像素域), 同步回系统域供回读
	// ★★ V37: 这些声明必须放在 jpeg_regfile 例化**之前**。
	//    V36 把 `wire [15:0] st_corr_fc = corr_t2[15:0];` 写在了例化之后的 229 行,
	//    但 166 行已经用到了它 => Verilog 在用法处隐式生成了一个 **1bit** net,
	//    于是 0xD0/0xD1 只接到 bit0, 读出来永远是 0 (TD 警告 HDL-7225)。
	//    诊断仪表自己的 bug 差点又被当成"真的没数据"。
	reg  [31:0] cnt_csi_pix, cnt_corr_pix, cnt_line_pix;
	reg  [31:0] cnt_s1, cnt_s2;
	reg  [31:0] csi_t1, csi_t2, corr_t1, corr_t2, line_t1, line_t2;
	wire [15:0] st_corr_fc = corr_t2[15:0];

	// 2026-10-20: RX 调试总线 2 级同步 (i_pix_clk -> i_sys_clk)
	//   值都是慢变化的电平, 2 级同步足够; 读 0xD6~0xD8 即可。
	reg  [7:0] dbg_mipi_s1,  dbg_mipi_s2;
	reg  [7:0] dbg_delay_s1, dbg_delay_s2;
	reg  [5:0] dbg_blen_s1,  dbg_blen_s2;
	reg        dbg_adone_s1, dbg_adone_s2;
	// 2026-10-21: 手动 tap 步进按钮 (idle=1)
	wire       cfg_dbg_btn;
	always @(posedge i_sys_clk or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			dbg_mipi_s1  <= 8'd0; dbg_mipi_s2  <= 8'd0;
			dbg_delay_s1 <= 8'd0; dbg_delay_s2 <= 8'd0;
			dbg_blen_s1  <= 6'd0; dbg_blen_s2  <= 6'd0;
			dbg_adone_s1 <= 1'b0; dbg_adone_s2 <= 1'b0;
		end else begin
			dbg_mipi_s1  <= i_dbg_mipi;      dbg_mipi_s2  <= dbg_mipi_s1;
			dbg_delay_s1 <= i_dbg_delay;     dbg_delay_s2 <= dbg_delay_s1;
			dbg_blen_s1  <= i_dbg_best_len;  dbg_blen_s2  <= dbg_blen_s1;
			dbg_adone_s1 <= i_dbg_autodone;  dbg_adone_s2 <= dbg_adone_s1;
		end
	end

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
		.O_cfg_pp_morph_th  (cfg_pp_morph_th),
		.O_cfg_pp_lap_shift (cfg_pp_lap_sh),
		.O_cfg_pp_prew_shift(cfg_pp_prew_sh),
		.O_cfg_pp_emboss_gain(cfg_pp_emboss_gain),
		.O_cfg_pp_emboss_bias(cfg_pp_emboss_bias),
		.O_cfg_pp_sharp_gain (cfg_pp_sharp_gain),
		.O_cfg_basic_en      (cfg_basic_en),
		.O_cfg_basic_gray    (cfg_basic_gray),
		.O_cfg_basic_gauss   (cfg_basic_gauss),
		.O_cfg_basic_ker     (cfg_basic_ker),
		.O_cfg_basic_he      (cfg_basic_he),
		.O_cfg_basic_he_clip (cfg_basic_he_clip),
		.O_cfg_basic_he_temp (cfg_basic_he_temp),
		.O_cfg_basic_linefix(cfg_basic_linefix),
		.O_cfg_basic_contrast(cfg_basic_contrast),
		.I_st_frame_cnt  (cnt_s2),
		.O_cfg_cam_exp   (cfg_cam_exp),
		.O_cfg_cam_gain  (cfg_cam_gain),
		.O_cfg_ev_bias   (cfg_cam_ev),
		.O_cfg_wb_r      (cfg_wb_r),
		.O_cfg_wb_b      (cfg_wb_b),
		.O_cfg_fps_div   (cfg_fps_div),
		.O_cfg_roi_pct   (cfg_roi_pct),
		.O_cfg_cam_trig  (cfg_cam_trig),
		.O_cfg_res_mode  (cfg_res_mode),   // V21
		.O_res_chg       (cfg_res_chg),    // V21
		.O_cfg_bayer_sel (cfg_bayer_sel),  // 2026-10-21
		.I_st_cam_wr_cnt (st_corr_fc),
		.I_st_cam_busy   (i_cam_busy),
          .I_st_line_groups(lg_max),
          // 2026-10-20: RX 调试总线 (已 2 级同步到 i_sys_clk)
          .I_dbg_mipi      (dbg_mipi_s2),
          .I_dbg_delay     (dbg_delay_s2),
          .I_dbg_best_len  (dbg_blen_s2),
          .I_dbg_autodone  (dbg_adone_s2),
          .O_dbg_btn       (cfg_dbg_btn)
  );

	assign o_dbg_btn = cfg_dbg_btn;
	assign o_bayer_sel = bsel_s2;   // 2026-10-21: 已在像素域

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
	//  V36: 原来的 i_frame_tuser (=S_ISP_O_tuser) 实测恒为 0, 计数器 0xB8 一直是 0,
	//       害得我们无法判定"传感器只给 12.5fps"还是"FPGA 只吐 12.5fps"。
	//       现在改成两个一定存在的信号:
	//         0xB8..0xBB <-- CSI-2 FS 短包计数 = 传感器真实帧率 (最关键的数)
	//         0xD0/0xD1  <-- ui_image_correction 输出帧计数(低16位, 会回转)
	//       另存一个行计数 cnt_line_pix, 当前未引出, 留着以后用。
	//      (声明已提前到 jpeg_regfile 例化之前, 见上面 V37 注释)
	//-------------------------------------------------------------------------

	always @(posedge i_pix_clk or negedge i_pix_rst_n) begin
		if (!i_pix_rst_n) begin
			cnt_csi_pix  <= 32'd0;
			cnt_corr_pix <= 32'd0;
			cnt_line_pix <= 32'd0;
		end else begin
			if (i_fs_csi)     cnt_csi_pix  <= cnt_csi_pix  + 32'd1;
			if (i_fs_corr)    cnt_corr_pix <= cnt_corr_pix + 32'd1;
			if (i_last_corr)  cnt_line_pix <= cnt_line_pix + 32'd1;
		end
	end

	always @(posedge i_sys_clk or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			cnt_s1 <= 32'd0; cnt_s2 <= 32'd0;
			csi_t1 <= 32'd0; csi_t2 <= 32'd0;
			corr_t1 <= 32'd0; corr_t2 <= 32'd0;
			line_t1 <= 32'd0; line_t2 <= 32'd0;
		end else begin
			csi_t1  <= cnt_csi_pix;  csi_t2  <= csi_t1;
			corr_t1 <= cnt_corr_pix; corr_t2 <= corr_t1;
			line_t1 <= cnt_line_pix; line_t2 <= line_t1;
			cnt_s1  <= csi_t2;       cnt_s2  <= cnt_s1;
		end
	end

	//-------------------------------------------------------------------------
	// 配置信号: 系统域 -> 像素域 (2 级同步)
	//-------------------------------------------------------------------------
	reg [3:0] mode_s1, mode_s2;
	reg [4:0] sh_s1,   sh_s2;
	reg [7:0] th_s1,   th_s2;
	reg       ms_s1,   ms_s2;
	// V45 高级新增参数
	reg [7:0] mth_s1,  mth_s2;
	reg [4:0] lap_s1,  lap_s2;
	reg [4:0] pre_s1,  pre_s2;
	reg [3:0] embg_s1, embg_s2;
	reg [7:0] embb_s1, embb_s2;
	reg [4:0] shp_s1,  shp_s2;
	// V45 初级
	reg [4:0] ben_s1,  ben_s2;
	reg       bgm_s1,  bgm_s2;
	reg [3:0] bga_s1,  bga_s2;
	reg [1:0] bkr_s1,  bkr_s2;
	reg [7:0] bhe_s1,  bhe_s2;
	reg [7:0] bhc_s1,  bhc_s2;
	reg [3:0] bht_s1,  bht_s2;
	reg       blf_s1,  blf_s2;
	reg [3:0] bct_s1,  bct_s2;
	reg [7:0] wbr_s1,  wbr_s2;
	reg [7:0] wbb_s1,  wbb_s2;
	reg [6:0] roi_s1,  roi_s2;
	reg [2:0] fps_s1,  fps_s2;
	reg [1:0] bsel_s1, bsel_s2;

	always @(posedge i_pix_clk or negedge i_pix_rst_n) begin
		if (!i_pix_rst_n) begin
			mode_s1 <= 4'd0; mode_s2 <= 4'd0;
			sh_s1 <= 5'd8;   sh_s2 <= 5'd8;
			th_s1 <= 8'd128; th_s2 <= 8'd128;
			ms_s1 <= 1'b1;   ms_s2 <= 1'b1;
			mth_s1<= 8'd128; mth_s2<= 8'd128;
			lap_s1<= 5'd8;   lap_s2<= 5'd8;
			pre_s1<= 5'd8;   pre_s2<= 5'd8;
			embg_s1 <= 4'd4; embg_s2 <= 4'd4;
			embb_s1 <= 8'd128; embb_s2 <= 8'd128;
			shp_s1<= 5'd8;   shp_s2<= 5'd8;
			ben_s1<= 5'd0;   ben_s2<= 5'd0;
			bgm_s1<= 1'b0;   bgm_s2<= 1'b0;
			bga_s1<= 4'd8;   bga_s2<= 4'd8;
			bkr_s1<= 2'd1;   bkr_s2<= 2'd1;
			bhe_s1<= 8'd255; bhe_s2<= 8'd255;
			bhc_s1<= 8'd255; bhc_s2<= 8'd255;
			bht_s1<= 4'd2;   bht_s2<= 4'd2;
			blf_s1<= 1'b0;   blf_s2<= 1'b0;
			bct_s1<= 4'd4;   bct_s2<= 4'd4;
			wbr_s1 <= 8'd128; wbr_s2 <= 8'd128;
			wbb_s1 <= 8'd128; wbb_s2 <= 8'd128;
			roi_s1 <= 7'd100; roi_s2 <= 7'd100;
			fps_s1 <= 3'd1;   fps_s2 <= 3'd1;
			bsel_s1 <= 2'd0;  bsel_s2 <= 2'd0;
		end else begin
			mode_s1 <= cfg_pp_mode; mode_s2 <= mode_s1;
			sh_s1   <= cfg_pp_sh;   sh_s2   <= sh_s1;
			th_s1   <= cfg_pp_th;   th_s2   <= th_s1;
			ms_s1   <= cfg_pp_ms;   ms_s2   <= ms_s1;
			mth_s1  <= cfg_pp_morph_th;  mth_s2  <= mth_s1;
			lap_s1  <= cfg_pp_lap_sh;    lap_s2  <= lap_s1;
			pre_s1  <= cfg_pp_prew_sh;   pre_s2  <= pre_s1;
			embg_s1 <= cfg_pp_emboss_gain; embg_s2 <= embg_s1;
			embb_s1 <= cfg_pp_emboss_bias; embb_s2 <= embb_s1;
			shp_s1  <= cfg_pp_sharp_gain;  shp_s2  <= shp_s1;
			ben_s1  <= cfg_basic_en;      ben_s2  <= ben_s1;
			bgm_s1  <= cfg_basic_gray;    bgm_s2  <= bgm_s1;
			bga_s1  <= cfg_basic_gauss;   bga_s2  <= bga_s1;
			bkr_s1  <= cfg_basic_ker;     bkr_s2  <= bkr_s1;
			bhe_s1  <= cfg_basic_he;      bhe_s2  <= bhe_s1;
			bhc_s1  <= cfg_basic_he_clip; bhc_s2  <= bhc_s1;
			bht_s1  <= cfg_basic_he_temp; bht_s2  <= bht_s1;
			blf_s1  <= cfg_basic_linefix; blf_s2  <= blf_s1;
			bct_s1  <= cfg_basic_contrast;bct_s2  <= bct_s1;
			// 这几个是慢变参数 (人手改的), 2 级同步足够;
			// 注意多比特跨域本应加握手, 但它们在“使用时”已经稳定了几十万个
			// 像素时钟, 不存在采样到中间态的实际窗口。
			wbr_s1  <= cfg_wb_r;    wbr_s2  <= wbr_s1;
			wbb_s1  <= cfg_wb_b;    wbb_s2  <= wbb_s1;
			roi_s1  <= cfg_roi_pct; roi_s2  <= roi_s1;
			fps_s1  <= cfg_fps_div; fps_s2  <= fps_s1;
			bsel_s1 <= cfg_bayer_sel; bsel_s2 <= bsel_s1;   // 2026-10-21
		end
	end

	// V39: RES_MODE 之前是"直接透传"，25MHz 寄存器直接进 147.5MHz 的 VTC/裁剪/
	//      dbuf 尺寸组合逻辑，是 STA 里 sys_clk -> clk4 的最差路径 (-4.949ns)。
	//      现在在像素域做 2 级同步，顶层拿到的 S_res_mode 已经是像素域寄存器；
	//      模式切换仍由 500ms 复位窗兜底。
	reg [1:0] res_mode_s1, res_mode_s2;
	always @(posedge i_pix_clk or negedge i_pix_rst_n) begin
		if (!i_pix_rst_n) begin
			res_mode_s1 <= 2'd0;
			res_mode_s2 <= 2'd0;
		end else begin
			res_mode_s1 <= cfg_res_mode;
			res_mode_s2 <= res_mode_s1;
		end
	end

	assign o_pp_mode        = mode_s2;
	assign o_pp_sobel_gain = sh_s2;
	assign o_pp_thresh      = th_s2;
	assign o_pp_morph_sel   = ms_s2;
	assign o_pp_morph_th    = mth_s2;
	assign o_pp_lap_gain   = lap_s2;
	assign o_pp_prew_gain  = pre_s2;
	assign o_pp_emboss_gain = embg_s2;
	assign o_pp_emboss_bias = embb_s2;
	assign o_pp_sharp_gain  = shp_s2;
	assign o_basic_en       = ben_s2;
	assign o_basic_gray     = bgm_s2;
	assign o_basic_gauss    = bga_s2;
	assign o_basic_ker      = bkr_s2;
	assign o_basic_he       = bhe_s2;
	assign o_basic_he_clip  = bhc_s2;
	assign o_basic_he_temp  = bht_s2;
	assign o_basic_linefix  = blf_s2;
	assign o_basic_contrast = bct_s2;

	assign o_wb_r    = wbr_s2;
	assign o_wb_b    = wbb_s2;
	// V21 诊断: i_line_groups 来自 S_hs_rx_clk 域, 2 级同步到 i_sys_clk 后取历史最大值。
	// 取最大值可自动滤掉跨时钟采样时可能出现的瞬时撕裂值, 读数稳定。
	// V39: 切模式时清空 400ms，避免 0xD4/0xD5 保留上一个模式的 966，
	//      导致切回 1080p 后仍显示 966。
	reg [23:0] lg_blank;
	always @(posedge i_sys_clk or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			lg_s1 <= 16'd0; lg_s2 <= 16'd0; lg_max <= 16'd0; lg_blank <= 24'd0;
		end else begin
			lg_s1 <= i_line_groups;
			lg_s2 <= lg_s1;
			// 400ms @25MHz：覆盖 D-PHY RX 复位(约 250ms)+传感器全表重写，
			// 否则 RX 时钟停住期间 i_line_groups 会冻结在旧模式的 966。
			if (cfg_res_chg)          lg_blank <= 24'd10_000_000;
			else if (lg_blank != 0)   lg_blank <= lg_blank - 24'd1;

			if (cfg_res_chg || lg_blank != 0)
				lg_max <= 16'd0;
			else if (lg_s2 > lg_max)
				lg_max <= lg_s2;
		end
	end

	assign o_roi_pct = roi_s2;
	assign o_fps_div = fps_s2;
	// V39: 使用像素域 2 级同步后的 mode (见上面的 res_mode_s1/s2)
	assign o_res_mode = res_mode_s2;
	assign o_res_chg  = cfg_res_chg;

	// 摄像头参数仍在 25MHz 域 (cam_param 也挂这个域), 不用同步
	assign o_cam_exp  = cfg_cam_exp;
	assign o_cam_gain = cfg_cam_gain;
	assign o_cam_ev   = cfg_cam_ev;
	assign o_cam_trig = cfg_cam_trig;

endmodule
