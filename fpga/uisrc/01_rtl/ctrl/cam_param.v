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
//
//  2026-10-16 (V24): **VMAX 和增益初值改成运行时输入**, 因为传感器现在能切
//  读出模式, 两个模式的帧长差很多:
//      1080p (2x2 binning): VMAX = 2283 行, HMAX = 542, SYS_MODE=0x05 (891Mbps)
//      4K    (all-pixel)  : VMAX = 3449 行, HMAX = 861, SYS_MODE=0x05 (891Mbps)  V38
//  曝光行数 = VMAX - SHR0, 所以 VMAX 算错的话曝光会差一倍。
//  增益初值也跟着变: 4K 灵敏度高, 初始化表只给 0x10 (4.8dB), binning 给 0x20。
//==============================================================================
module cam_param #(
	parameter [19:0] SHR0_DEFAULT = 20'd8       // 初始化表的 SHR0 (两个模式都是 8)
)(
	input  wire        clk,
	input  wire        rst_n,

	// ---- V24: 跟传感器读出模式走的常量 ----
	input  wire [19:0] i_vmax,       // 帧长(行): binning 2283, 4K 3449 (V38)
	input  wire [7:0]  i_gain_default,// 初始化表的 0x3090: binning 0x20, 4K 0x10

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
	wire [19:0] exp_base = (i_exp == 20'd0) ? (i_vmax - SHR0_DEFAULT)
	                                        : (i_vmax - i_exp);

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

	// 夹紧: 曝光行数 ≤ VMAX - SHR0_MIN, 且 ≥ 1
	//   ⚠ 修复(2026-10-16): SHR0 **不能压到 8 以下**。
	//     原来写的是 `(exp_ev >= VMAX) ? (VMAX-1)`, 于是 EV=+3 时
	//     exp_ev = 基准<<3 = 18200 > VMAX -> exp_cl = VMAX-1 -> SHR0 = 1。
	//     而 SHR0=1 对 IMX415 是无效/极短曝光, 画面直接变黑 ——
	//     实测 EV +3 与 -3 的平均亮度都是 ~9.6 (EV+3 本该保持最亮 237.6)。
	//     SHR0_MIN 取初始化表的默认值 8 (即最长曝光 2275 行 = 16.6ms)。
	//     注意: 基准曝光已经贴到上限时, +EV 本来就"没有余量"可加(只会被夹住),
	//     这是正确行为 —— 想要 +EV 提亮需要同时提增益, 那是另一件事。
	localparam [19:0] SHR0_MIN = 20'd8;
	wire [19:0] exp_max = i_vmax - SHR0_MIN;               // binning 2275 / 4K 4495
	wire [19:0] exp_cl = (exp_ev == 20'd0) ? 20'd1 :
	                     (exp_ev > exp_max) ? exp_max : exp_ev;

	wire  [19:0] exp_calc = i_vmax - exp_cl;   // 组合算出来的 SHR0

	//------------------------------------------------------------------ 增益
	wire [7:0] gain_use = (i_gain == 8'd0)  ? i_gain_default :
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

	//------------------------------------------------------------------- 看门狗
	// 参数下发链路一旦卡死, 网页就再也改不了曝光/增益, 而 FPGA 没有可用的
	// 软复位(0x0A SOFT_RST 是死寄存器) => 只能靠这里兜底自恢复。
	// busy 超过 WD_MAX 还没等到 ae_done 就放弃本轮。
	// 放弃时按"已处理"记账, 以免 need_send 恒真而反复重发打爆 I2C;
	// 用户下次改参数时会重新发起一轮。
	// 20ms 的依据(2026-10-16 实测): 一轮参数下发 = 7 个寄存器 x ~385us
	// (I2C 100kHz, 每次 4 字节) ≈ 2.7ms, 这里留 7 倍余量。
	// 原来写的 1ms **比真实一轮还短**, 于是每一轮都在真正写完之前就超时放弃:
	// CAM_WR_CNT 永远不涨, CAM_BUSY 也几乎看不到(实测 busy 只高 1.0ms 就落回)。
	localparam [19:0] WD_MAX = 20'd500000;
	reg [19:0] wd_cnt;
	reg [15:0] wd_timeout_cnt;   // 超时次数, 便于排查

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) wd_cnt <= 20'd0;
		else if (!busy) wd_cnt <= 20'd0;
		else if (wd_cnt != WD_MAX) wd_cnt <= wd_cnt + 20'd1;
	end
	wire wd_expire = (wd_cnt == WD_MAX);

	// ★★ 修复(2026-10-16): 下发期间把 o_rt_exp "钉"在 held_exp 上。
	//   网页把 20 位曝光拆成 3 个字节逐个写 I2C, 而 ui_cfg_imx415 的 AE 链是每写
	//   一个寄存器就组合取一次当前值 => 链正好跨在那 3 次写中间时, 会把新旧字节
	//   混起来写进传感器(实测出现过设了 100 却连续几十秒黑屏)。
	//   钉住之后一轮内恒为定值; 若期间又来新值, 本轮结束后
	//   exp_calc != exp_d 会自然再发起一轮, 所以只需要多一轮就收敛。
	assign o_rt_exp = busy ? held_exp : exp_calc;

	// 参数与「上一次已生效的值」不同 -> 需要重发
	//   (i_trig 变化也走这条路, 用于强制刷新, 比如上电后先把参数灌一次)
	wire need_send = (exp_calc != exp_d) | (gain_use != gain_d) | (i_trig != trig_d);

	assign o_busy = busy;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			o_ae_req  <= 1'b0;
			o_ae_gain <= i_gain_default;
			o_wr_cnt  <= 16'd0;
			exp_d     <= 20'd0;
			gain_d    <= 8'd0;
			trig_d    <= 8'd0;
			held_exp  <= 20'd0;
			held_gain <= 8'd0;
			busy      <= 1'b0;
			wd_timeout_cnt <= 16'd0;
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
			end else if (ae_done_rise || wd_expire) begin
				// 一轮写完: 记下已生效的值, 参数再变才会重新下发
				// 看门狗超时: 当作已完成(不重复重发), 只累加超时计数
				exp_d    <= held_exp;
				gain_d   <= held_gain;
				trig_d   <= i_trig;
				busy     <= 1'b0;
				if (ae_done_rise) begin
					o_wr_cnt <= o_wr_cnt + 16'd1;
				end else begin
					wd_timeout_cnt <= wd_timeout_cnt + 16'd1;
				end
			end
		end
	end

endmodule
