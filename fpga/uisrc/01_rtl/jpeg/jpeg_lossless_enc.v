/*===========================================================================
 * Filename     : jpeg_lossless_enc.v
 * Description  : 无损 JPEG (SOF3) 的 DPCM 预测编码
 *
 *  参考: ITU-T T.81 Annex H (lossless) + Annex K.3 的 lossless DC 表
 *
 *  ★ 为什么只需缓存【上一行】:
 *      4:2:2 无损模式下最小编码单元是 1 个采样宽度, 所以一个 MCU 就是
 *      「Y0, Y1, Cb, Cr」四个采样 —— 正好是 1 个 YUV422 word (2 像素)。
 *      预测器需要 a(左)/b(上)/c(左上):
 *        Y0  : a = 上一 word 的 Y1, b = 上行同列 Y0, c = 上行前一列 Y1
 *        Y1  : a = 本 word 的 Y0,  b = 上行同列 Y1, c = 上行同列 Y0
 *        Cb/Cr 同理
 *      所以只要保存整行上一行 + 当前行前一个 word, 就能流式处理。
 *
 *  ★ 预测器用 MED (LOCO-I 的 median edge detector), 比固定的 1~7 号预测器
 *    在自然图像上残差熵更低:
 *        mx = max(a,b); mn = min(a,b)
 *        c >= mx  -> Px = mn
 *        c <= mn  -> Px = mx
 *        否则      -> Px = a + b - c   (再 clamp 到 0..255)
 *
 *  ★ 边界处理: 不存在的邻居一律用 0。
 *      第一行: b=c=0 -> MED 退化为 a;  第一列: a=c=0 -> MED 退化为 b;
 *      左上角: a=b=c=0 -> Px=0。与 T.81 的边界约定一致, 无需特判分支。
 *
 *  吞吐: 每 word 编 4 个符号, 1 符号/拍 -> 4 拍/word。
 *        1080p = 960*1080 = 1.037M word -> 4.15M 拍/帧 -> ~35fps @147.5MHz
 *        (输入本身只要 1 拍/word, 所以编码是瓶颈; 要更高帧率需 4 符号并行)
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_lossless_enc #(
    parameter integer W = 1920
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i_start,         // 帧首脉冲: 清上一行与左邻

    // 输入 YUV422 word {Cr, Y1, Cb, Y0}
    input  wire        i_valid,
    input  wire [31:0] i_data,
    output wire        i_ready,

    // 熵编码输出 (接 jpeg_bitpack)
    output reg         o_valid,
    output reg  [31:0] o_code,
    output reg  [5:0]  o_len,
    input  wire        i_out_ready,

    output reg         o_done,
    output reg  [31:0] o_sample_cnt     // 已编码的采样数 (诊断)
);

    `undef JPEG_DEFS_VH
    `include "jpeg_defs.vh"

    localparam integer WX = W / 2;      // 每行 word 数
    localparam integer CW = $clog2(WX); // 列索引位宽
    localparam integer WXP = 1 << CW;   // 补齐到 2 的幂 (拼接地址要求)

    //=============================================================== MED 预测器
    function [7:0] med;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        reg   [7:0] mx, mn;
        reg signed [9:0] t;
        begin
            mx = (a > b) ? a : b;
            mn = (a < b) ? a : b;
            if (c >= mx) begin
                med = mn;
            end else if (c <= mn) begin
                med = mx;
            end else begin
                t = $signed({2'b00, a}) + $signed({2'b00, b}) - $signed({2'b00, c});
                if (t > 10'sd255)      med = 8'd255;
                else if (t < 10'sd0)   med = 8'd0;
                else                   med = t[7:0];
            end
        end
    endfunction

    //=============================================================== 存储
    // ★ 必须双缓冲: 写【当前行】的同时要读【上一行】。
    //   原来只有一份 prev_line 边写边读, 同一行的 upl(左上) 会读到当前行已经
    //   写进去的数据 —— 实测 word1 的 c 变成了 word0 的 Y1, 预测值全错。
    reg [31:0] line_buf [0:2*WXP-1];
    reg        wr_buf;                  // 0/1: 当前写入的缓冲区
    reg [31:0] cur_left;                // 当前行前一个 word

    integer pi;
    initial begin
        for (pi = 0; pi < 2*WXP; pi = pi + 1) line_buf[pi] = 32'd0;
        cur_left = 32'd0;
        wr_buf   = 1'b0;
    end

    reg [10:0] col;                     // 0..WX-1

    //=============================================================== 输入寄存
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_ENC  = 2'd1;

    reg [1:0] state;
    reg [1:0] step;                     // 0=Y0 1=Y1 2=Cb 3=Cr

    reg        in_have;
    reg [31:0] in_word;

    // i_start 拍不接收, 避免清缓冲的同时把上游数据吞掉
    assign i_ready = (!in_have) && (state == S_IDLE) && i_out_ready && !i_start;

    // 当前 word 的 4 个采样
    wire [7:0] w_y0 = in_word[7:0];
    wire [7:0] w_cb = in_word[15:8];
    wire [7:0] w_y1 = in_word[23:16];
    wire [7:0] w_cr = in_word[31:24];

    // 邻居
    //   up_*  : 上一行【同列】       (= 非写缓冲)
    //   upl_* : 上一行【前一列】     (= MED 的 c)
    //   ★ 不能用同列代替前一列
    // col-1: 在 CW 位下 "减 1" 等价于 "加全 1" (模 2^CW), 且不会借位到 buf 位
    wire [31:0] cur_up  = line_buf[{~wr_buf, col[CW-1:0]}];
    wire [31:0] cur_upl = (col == 11'd0) ? 32'd0
                                        : line_buf[{~wr_buf, col[CW-1:0] + {CW{1'b1}}}];

    wire [7:0] up_y0 = cur_up[7:0];
    wire [7:0] up_cb = cur_up[15:8];
    wire [7:0] up_y1 = cur_up[23:16];
    wire [7:0] up_cr = cur_up[31:24];

    wire [7:0] upl_y1 = cur_upl[23:16];
    wire [7:0] upl_cb = cur_upl[15:8];
    wire [7:0] upl_cr = cur_upl[31:24];

    wire [7:0] lf_y1 = cur_left[23:16];
    wire [7:0] lf_cb = cur_left[15:8];
    wire [7:0] lf_cr = cur_left[31:24];

    // 当前采样、预测值、残差
    reg [7:0] px;
    reg [7:0] pv;
    reg signed [9:0] diff;
    reg [15:0] mag;
    reg [3:0]  ssss;
    reg [20:0] tab;
    reg signed [15:0] amp;
    reg [15:0] mask;

    always @(*) begin
        case (step)
        // Y0: a=上一word的Y1(行首为0)  b=上行Y0  c=上行前一列Y1
        2'd0: begin
            px = w_y0;
            pv = med(lf_y1, up_y0, upl_y1);
        end
        // Y1: a=本word的Y0  b=上行Y1  c=上行同列Y0
        2'd1: begin
            px = w_y1;
            pv = med(w_y0, up_y1, up_y0);
        end
        // Cb: a=上一word的Cb  b=上行Cb  c=上行前一列Cb
        2'd2: begin
            px = w_cb;
            pv = med(lf_cb, up_cb, upl_cb);
        end
        default: begin
            px = w_cr;
            pv = med(lf_cr, up_cr, upl_cr);
        end
        endcase

        diff  = $signed({2'b00, px}) - $signed({2'b00, pv});
        mag   = diff[9] ? (-diff) : diff;
        ssss  = jpeg_ssss(mag);
        tab   = jpeg_huff_lossless(ssss);
        amp   = (diff >= 0) ? diff : (diff + (10'sd1 << ssss) - 10'sd1);
        mask  = (16'd1 << ssss) - 16'd1;
    end

    //=============================================================== 主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            step         <= 2'd0;
            col          <= 11'd0;
            in_have      <= 1'b0;
            in_word      <= 32'd0;
            cur_left     <= 32'd0;
            wr_buf       <= 1'b0;
            o_valid      <= 1'b0;
            o_code       <= 32'd0;
            o_len        <= 6'd0;
            o_done       <= 1'b0;
            o_sample_cnt <= 32'd0;
        end else begin
            o_valid <= 1'b0;
            o_done  <= 1'b0;

            if (i_start) begin
                state <= S_IDLE;
                step  <= 2'd0;
                col   <= 11'd0;
                in_have <= 1'b0;
                cur_left <= 32'd0;
                wr_buf   <= 1'b0;
                for (pi = 0; pi < 2*WXP; pi = pi + 1) line_buf[pi] <= 32'd0;
                o_sample_cnt <= 32'd0;
            end else begin
                case (state)
                //------------------------------------------------
                S_IDLE: begin
                    if (i_valid && !in_have && i_out_ready) begin
                        in_word <= i_data;
                        in_have <= 1'b1;
                        step    <= 2'd0;
                        state   <= S_ENC;
                    end
                end

                //------------------------------------------------
                // 每个采样一拍: 查表 -> 输出 -> 下一步
                S_ENC: begin
                    if (i_out_ready) begin
                        o_valid <= 1'b1;
                        o_code  <= ({16'd0, tab[15:0]} << ssss)
                                 | {16'd0, amp & $signed(mask)};
                        o_len   <= tab[20:16] + {2'd0, ssss};
                        o_sample_cnt <= o_sample_cnt + 32'd1;

                        if (step == 2'd3) begin
                            // 该 word 编码完毕: 写入【当前】行缓冲
                            line_buf[{wr_buf, col[CW-1:0]}] <= in_word;
                            in_have        <= 1'b0;
                            step           <= 2'd0;
                            state          <= S_IDLE;

                            if (col == WX - 1) begin
                                // 行尾: 左邻清零, 交换读写缓冲
                                col      <= 11'd0;
                                cur_left <= 32'd0;
                                wr_buf   <= ~wr_buf;
                                o_done   <= 1'b1;
                            end else begin
                                col      <= col + 11'd1;
                                cur_left <= in_word;
                            end
                        end else begin
                            step <= step + 2'd1;
                        end
                    end
                end

                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
