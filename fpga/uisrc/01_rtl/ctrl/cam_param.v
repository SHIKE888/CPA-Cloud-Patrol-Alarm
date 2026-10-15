`timescale 1ns/1ps
//==============================================================================
//  cam_param.v —— 摄像头 (IMX415) 参数换算 + 下发触发
//
//  把寄存器堆里的「曝光 / 增益 / 曝光补偿」换算成 IMX415 的寄存器值, 并在参数
//  变化时触发一次 I2C 配置。真正写总线由 ui_cfg_imx415 的参数阶段完成 ——
//  本模块只负责「产生请求 + 提供数据」, 所以不需要碰 I2C 时序。
//
//  ── IMX415 曝光模型 ──
//      曝光行数 = VMAX - SHR0
//      VMAX = 0x0008EB = 2283 行   (见 ui_imx415_reg.v 的 0x3024/25/26)
//      SHR0 = 初始化表给的 0x08 -> 曝光 2275 行
//      行周期 = HMAX / 像素时钟 = 542 / 74.25MHz = 7.3us
//   => 曝光时间 = (VMAX - SHR0) * 7.3us
//      SHR0 = 8    -> 16.6ms  (初始化表默认, 最亮)
//      SHR0 = 2275 -> 0.058ms (最短)
//      也就是 SHR0 越大曝光越短, 别搞反。
//
//  ── 曝光补偿 EV ──
//      EV 对「曝光行数」做倍数修正: exp = exp_base * 2^EV
//      寄存器里用偏移 8 表示 0EV (0..15 -> -8..+7), 实用范围限在 -3..+3。
//
//  ── 增益 ──
//      0x3090 GAIN_PGC_0, 取值 0..100 (0.3dB/step, 0x64=100=30dB)。
//      4 个通道 0x3090/92/94/96 写同一个值。
//
//  2026-10-15: 原来 I_ae_req 由厂商的 ui_ae_set 驱动, 而它依赖 VPI 探针
//  (outprobe0), 该探针的初值在工程里是 0x50 但一旦 VPI 没被 JTAG 写过就不
//  确定。现在改由本模块驱动, 参数完全可控且可从网页设置。
//==============================================================================
module cam_param #(
	parameter [19:0] VMAX         = 20'd2283,   // 帧长(行)
	parameter [19:0] SHR0_DEFAULT = 20'd8,      // 初始化表的 SHR0
	parameter [7:0]  GAIN_DEFAULT = 8'h30       // 初始化表的 0x3090
)(
	input  wire        clk,
	input  wire        rst_n,

	// ---- 来自寄存器堆 (0xC0 起) ----
	input  wire [19:0] i_exp,        // SHR0, 0 = 用初始化表的默认
	input  wire [7:0]  i_gain,       // 0..100, 0 = 用初始化表的默认
	input  wire [3:0]  i_ev_bias,    // 曝光补偿, 偏移 8 = 0EV
	input  wire [7:0]  i_trig,       // 写任意值 -> 强制重新下发一次

	// ---- 给 ui_cfg_imx415 的参数通道 ----
	output reg         o_ae_req,     // 一拍脉冲
	output reg  [7:0]  o_ae_gain,    // 4 个增益通道的值
	output wire [19:0] o_rt_exp,     // SHR0 (3 字节)
	input  wire        i_ae_done,    // ui_cfg_imx415 的 O_ae_cfg_done

	// ---- 状态 ----
	output reg  [15:0] o_wr_cnt,     // 已下发的次数
	output wire        o_busy
);

	//------------------------------------------------------------------ 曝光换算
	wire [19:0] exp_base = (i_exp == 20'd0) ? (VMAX - SHR0_DEFAULT)
	                                        : (VMAX - i_exp);

	// EV 倍数: 桶形移位, 不用动态移位量以免综合出大逻辑
	wire [2:0]  ev_mag = (i_ev_bias >= 4'd8) ? i_ev_bias[2:0]
	                                         : (4'd8 - i_ev_bias);
	wire        ev_up  = (i_ev_bias > 4'd8);
	wire [19:0] exp_up = (ev_mag == 3'd0) ? exp_base :
	                     (ev_mag == 3'd1) ? (exp_base << 1) :
	                     (ev_mag == 3'd2) ? (exp_base << 2) :
	                                        (exp_base << 3);
	wire [19:0] exp_dn = (ev_mag == 3'd0) ? exp_base :
	                     (ev_mag == 3'd1) ? (exp_base >> 1) :
	                     (ev_mag == 3'd2) ? (exp_base >> 2) :
	                                        (exp_base >> 3);
	wire [19:0] exp_ev = ev_up ? exp_up : exp_dn;

	// 夹紧: 至少 1 行, 最多 VMAX-1 行
	wire [19:0] exp_cl = (exp_ev == 20'd0) ? 20'd1 :
	                     (exp_ev >= VMAX)  ? (VMAX - 20'd1) : exp_ev;

	assign o_rt_exp = VMAX - exp_cl;      // SHR0

	//------------------------------------------------------------------ 增益
	wire [7:0] gain_use = (i_gain == 8'd0)  ? GAIN_DEFAULT :
	                      (i_gain > 8'd100) ? 8'd100 : i_gain;

	//------------------------------------------------------------------ 变化检测
	reg [19:0] exp_d;
	reg [7:0]  gain_d;
	reg [7:0]  trig_d;
	reg [19:0] held_exp;
	reg [7:0]  held_gain;
	reg        busy;

	// ae_done 的上升沿 = 一轮参数写完了
	reg  ae_done_d;
	wire ae_done_rise = i_ae_done & ~ae_done_d;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) ae_done_d <= 1'b0;
		else        ae_done_d <= i_ae_done;
	end

	// 参数与「上一次已生效的值」不同 -> 需要重发
	//   (i_trig 变化也走这条路, 用于强制刷新, 比如上电后先把参数灌一次)
	wire need_send = (o_rt_exp != exp_d) | (gain_use != gain_d) | (i_trig != trig_d);

	assign o_busy = busy;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			o_ae_req  <= 1'b0;
			o_ae_gain <= GAIN_DEFAULT;
			o_wr_cnt  <= 16'd0;
			exp_d     <= 20'd0;
			gain_d    <= 8'd0;
			trig_d    <= 8'd0;
			held_exp  <= 20'd0;
			held_gain <= 8'd0;
			busy      <= 1'b0;
		end else begin
			o_ae_req <= 1'b0;                     // 默认低, 脉冲式

			if (!busy) begin
				// 上电后第一次必然 need_send (exp_d/gain_d 初值为 0)
				if (need_send) begin
					held_exp  <= o_rt_exp;
					held_gain <= gain_use;
					o_ae_gain <= gain_use;
					o_ae_req  <= 1'b1;
					busy      <= 1'b1;
				end
			end else if (ae_done_rise) begin
				// 一轮写完: 记下已生效的值, 参数再变才会重新下发
				exp_d    <= held_exp;
				gain_d   <= held_gain;
				trig_d   <= i_trig;
				o_wr_cnt <= o_wr_cnt + 16'd1;
				busy     <= 1'b0;
			end
		end
	end

endmodule
