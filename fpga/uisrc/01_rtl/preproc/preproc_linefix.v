//=============================================================================
//  preproc_linefix.v —— 行边界后移 16 像素（修"行首 16 像素是上一行行尾"）
//
//  ── 现象本质（板上实测）──────────────────────────────────────────────────
//  预处理链每级 3x3 需要"下一组像素"才能组窗口，4 级串联后**内容比行边界晚
//  16 个像素**：
//      out_line(L) = C(L-1)[1904..1919] ++ C(L)[0..1903]
//  所以每行开头的 16 个像素是上一行的行尾（画面左侧红/黑竖条），
//  而每行总像素仍是 1920（相邻行位移实测为 0）。
//
//  ── 修法：只挪边界，不搬数据 ─────────────────────────────────────────────
//  把 tuser / tlast（行/帧边界标记）往后延迟 4 个字 = 16 像素，
//  数据与 tvalid 完全不动。于是：
//      out_line(L) = C(L)[0..1919]            ← 正好是本行内容
//  上一行行尾那 16 个像素仍然输出，只是归到上一行末尾：
//  不丢像素、不加像素、行长度不变、不需要行同步信号。
//
//  ── 为什么不是"删掉多余像素" ────────────────────────────────────────────
//  那 16 个像素不是多余的，是上一行真实的行尾；删掉会丢数据且每行变 1904
//  像素（行长度错 → 整屏斜）。
//
//  ⚠ i_en = 0 时完全直通（0 延迟），便于 A/B；由 0xFB 控制，默认开。
//=============================================================================
`timescale 1ns / 1ps

module preproc_linefix #(
	parameter integer PX_PER_CLK = 4
)(
	input  wire         clk,
	input  wire         rst_n,
	input  wire [12:0]  i_h_active,     // 保留端口(本方案不用)
	input  wire         i_en,           // 1 = 边界后移 16 像素

	input  wire         i_tvalid,
	input  wire         i_tuser,
	input  wire         i_tlast,
	input  wire [127:0] i_rgb,

	output wire         o_tvalid,
	output wire         o_tuser,
	output wire         o_tlast,
	output wire [127:0] o_rgb
);

	localparam integer SH = 4;          // 后移字数 = 16 像素 / 4

	reg [SH-1:0] u_sr, t_sr;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			u_sr <= {SH{1'b0}};
			t_sr <= {SH{1'b0}};
		end else if (i_tvalid) begin
			u_sr <= {u_sr[SH-2:0], i_tuser};
			t_sr <= {t_sr[SH-2:0], i_tlast};
		end
		// ⚠ 行消隐(i_tvalid=0)时必须**保持**，不能清零 ——
		//   清零会把移位链打断，tuser 延迟失效，下游按错误边界分行(密集黑条)。
	end

	// 数据与 tvalid 直通；tuser/tlast 也必须是**组合**输出：
	// 旧版把 o_tuser/o_tlast 写成寄存器，使它们比数据晚 1 拍，
	// 每行行尾会混入下一行 1 组、行首丢 1 组 -> 整屏周期性错位。
	assign o_tvalid = i_tvalid;
	assign o_rgb    = i_rgb;
	assign o_tuser  = i_en ? u_sr[SH-1] : i_tuser;
	assign o_tlast  = i_en ? t_sr[SH-1] : i_tlast;

endmodule
