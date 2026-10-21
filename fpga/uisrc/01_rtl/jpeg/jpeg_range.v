/*===========================================================================
 * Filename     : jpeg_range.v
 * Description  : BT.709 limited (Y 16-235 / C 16-240) -> full range (0-255)
 *
 *   为什么必须有这一步:
 *     MIPI 上来的 YUV 是 limited range。JPEG 的 SOF0 规范默认 full range，
 *     直接把 limited 数据塞进去会整体发灰、对比度不足(黑不到 0, 白不到 255)。
 *
 *   为什么必须用 floor(截断) 而不是四舍五入:
 *     tools/jpeg_ref.py 的 expand_range() 用的是 `//`, 对负数即 floor。
 *     本模块用「倒数定点乘 + 算术右移」, 算术右移天然就是 floor,
 *     两边语义一致才能逐字节比对。
 *
 *   系数推导:
 *     Y' = (Y - 16) * 255/219
 *        ceil(2^16 * 255/219) = 76312   (76312/65536 = 1.16446 > 255/219 = 1.16438)
 *        ⚠ 用 ceil 而不是 round: 若用 round(76311.6)=76312 同一个值, 但必须验证
 *          对全部 220 个合法输入 floor 结果都与 255*x//219 一致 —— 已核对 ✓
 *     C' = (C - 128) * 255/224 + 128
 *        round(2^16 * 255/224) = round(74605.7) = 74606
 *
 *   吞吐: 1 个 32bit word = 2 像素 + 1 组 CbCr, 1 word/clk。
 *         4 个乘法器(2×Y + 2×C), 1 级流水。
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_range (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i_valid,
    input  wire [31:0] i_data,      // {Cr, Y1, Cb, Y0}  (YUYV 排列)
    output reg         o_valid,
    output reg  [31:0] o_data,

    // 1 = 做色域扩展, 0 = 原样透传 (调试/已 full range 时用)
    input  wire        i_en
);

    //--------------------------------------------------------------- 定点系数
    localparam signed [25:0] K_Y = 26'sd76312;   // 2^16 * 255/219, ceil
    localparam signed [25:0] K_C = 26'sd74606;   // 2^16 * 255/224, round

    //--------------------------------------------------------------- 组合函数
    // Y: 需要 26 位中间结果 (最大 (255-16)*76312 = 18.2e6 < 2^25)
    function [7:0] f_y;
        input [7:0] v;
        reg signed [25:0] p;
        begin
            p = ($signed({2'b00, v}) - 26'sd16) * K_Y;
            p = p >>> 16;                       // 算术右移 = floor
            if (p[25])           f_y = 8'd0;    // 负 -> 0
            else if (p > 26'sd255) f_y = 8'd255;
            else                 f_y = p[7:0];
        end
    endfunction

    // C: 偏差以 128 为中心, 结果再 +128
    function [7:0] f_c;
        input [7:0] v;
        reg signed [25:0] p;
        begin
            p = ($signed({2'b00, v}) - 26'sd128) * K_C;
            p = (p >>> 16) + 26'sd128;
            if (p[25])           f_c = 8'd0;
            else if (p > 26'sd255) f_c = 8'd255;
            else                 f_c = p[7:0];
        end
    endfunction

    //--------------------------------------------------------------- 流水
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid <= 1'b0;
            o_data  <= 32'd0;
        end else begin
            o_valid <= i_valid;
            if (!i_valid) begin
                o_data <= 32'd0;
            end else if (!i_en) begin
                o_data <= i_data;                       // 透传
            end else begin
                o_data <= { f_c(i_data[31:24]),         // Cr'
                            f_y(i_data[23:16]),         // Y1'
                            f_c(i_data[15:8] ),         // Cb'
                            f_y(i_data[7:0]  ) };       // Y0'
            end
        end
    end

endmodule
