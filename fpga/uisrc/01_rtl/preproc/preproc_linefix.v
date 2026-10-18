//=============================================================================
//  preproc_linefix.v —— 行首 16 像素校正（可开关，寄存器 0xFB）
//
//  ── 板上实测现象（原始 NV16）────────────────────────────────────────────
//  预处理链（4 级 3x3 窗口）每行输出的前 16 个像素不是本行内容：
//      x=0..11  : 同一组 4 像素重复 3 遍（上一行行尾）
//      x=12..15 : Y=22 / Cb=Cr=128（limited 黑）
//  行长度仍是 1920（相邻行位移实测 0），所以真实内容被顶到下一行行首，
//  画面左侧就出现彩条。
//
//  ── 本模块做什么 ───────────────────────────────────────────────────────
//  每行做一次"左旋 4 个字（16 像素）"：
//      out_line = in_line[4..479] ++ in_line[0..3]
//  行长度、拍数完全不变，只改行内顺序；行首从本行第 5 个字开始，
//  行首那组脏数据被搬到行尾（它本来就是上一行行尾，看起来接近正常内容）。
//
//  ⚠ 默认关闭（i_en=0 时纯直通，只多 1 拍延迟）。因为"左旋"的方向是否正好
//    对，取决于脏数据来自哪一级，必须在板上用 0xFB 实测确认再默认打开。
//=============================================================================
`timescale 1ns / 1ps

module preproc_linefix #(
	parameter integer PX_PER_CLK = 4
)(
	input  wire         clk,
	input  wire         rst_n,
	input  wire [12:0]  i_h_active,
	input  wire         i_en,               // 0 = 直通, 1 = 行首左旋 16 像素

	input  wire         i_tvalid,
	input  wire         i_tuser,
	input  wire         i_tlast,
	input  wire [127:0] i_rgb,

	output reg          o_tvalid,
	output reg          o_tuser,
	output reg          o_tlast,
	output reg  [127:0] o_rgb
);

	localparam integer LT = 4;              // 旋掉的字数 = 16 像素 / 4

	wire [12:0] nw = i_h_active >> 2;       // 每行字数

	reg [12:0]  grp;                        // 行内字序号 0..nw-1
	reg [127:0] h0, h1, h2, h3;             // 行首 4 个字
	reg         u_d, t_d;

	wire [127:0] hsel = (grp == 13'd0) ? h0 :
	                    (grp == 13'd1) ? h1 :
	                    (grp == 13'd2) ? h2 : h3;

	wire in_head = i_en && (grp < LT);

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			grp <= 13'd0;
			h0 <= 128'd0; h1 <= 128'd0; h2 <= 128'd0; h3 <= 128'd0;
			u_d <= 1'b0; t_d <= 1'b0;
			o_tvalid <= 1'b0; o_tuser <= 1'b0; o_tlast <= 1'b0;
			o_rgb <= 128'd0;
		end else begin
			o_tvalid <= i_tvalid;
			o_tuser  <= u_d;
			o_tlast  <= t_d;
			u_d      <= i_tuser;
			t_d      <= i_tlast;

			if (i_tvalid) begin
				if (in_head) begin
					o_rgb <= hsel;              // 上一行行首存的 4 个字 → 本行行尾
					case (grp)
						13'd0: h0 <= i_rgb;
						13'd1: h1 <= i_rgb;
						13'd2: h2 <= i_rgb;
						default: h3 <= i_rgb;
					endcase
				end else begin
					o_rgb <= i_rgb;
				end

				if (nw != 13'd0 && grp == (nw - 13'd1)) grp <= 13'd0;
				else                                    grp <= grp + 13'd1;
			end
		end
	end

endmodule
