//=============================================================================
//  preproc_line1.v —— 单行延迟（原图）1 像素对齐
//
//  3x3 滤波的输出天然滞后 1 行（必须看到"下一行"才能算中间行），
//  所以 mix8(原图, 滤波结果) 里的"原图"也必须滞后相同的行数。
//
//  延迟 = 1 拍；输出 = 上一行同一列。
//  级/并联 3 个即可得到 n-1 / n-2 / n-3 三行原图。
//=============================================================================
`timescale 1ns / 1ps

module preproc_line1 (
	input  wire         clk,
	input  wire         rst_n,
	input  wire [15:0]  I_nw,

	input  wire         i_tvalid,
	input  wire         i_tuser,
	input  wire         i_tlast,
	input  wire [127:0] i_rgb,

	output reg          o_tvalid,
	output reg          o_tuser,
	output reg          o_tlast,
	output reg  [127:0] o_rgb
);

	localparam integer AW  = 10;
	localparam integer DEP = 960;

	reg [95:0]   mem [0:DEP-1];
	reg [AW-1:0] wcol;

	wire [95:0] rgb4 = {i_rgb[119:96], i_rgb[87:64], i_rgb[55:32], i_rgb[23:0]};
	wire wlast = (wcol == I_nw[AW-1:0] - 1'b1);

	reg [95:0] q;

	always @(posedge clk) begin
		if (i_tvalid) mem[wcol] <= rgb4;
	end

	always @(posedge clk) begin
		q <= mem[wcol];                       // 同步读: 下一拍得到"上一行同列"
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			wcol <= {AW{1'b0}};
		end else if (i_tvalid) begin
			if (i_tuser)      wcol <= {AW{1'b0}};
			else if (wlast)   wcol <= {AW{1'b0}};
			else              wcol <= wcol + 1'b1;
		end
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			o_tvalid <= 1'b0;
			o_tuser  <= 1'b0;
			o_tlast  <= 1'b0;
			o_rgb    <= 128'd0;
		end else begin
			o_tvalid <= i_tvalid;
			o_tuser  <= i_tuser;
			o_tlast  <= i_tlast;
			o_rgb    <= {
				{8'h00, q[95:88], q[87:80], q[79:72]},
				{8'h00, q[71:64], q[63:56], q[55:48]},
				{8'h00, q[47:40], q[39:32], q[31:24]},
				{8'h00, q[23:16], q[15:8],  q[7:0]}
			};
		end
	end

endmodule
