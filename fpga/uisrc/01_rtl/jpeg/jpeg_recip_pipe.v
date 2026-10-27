/*===========================================================================
 * Filename     : jpeg_recip_pipe.v
 * Description  : 量化倒数表 round(2^20 / Q) 的 22 级流水长除法
 *
 *  为什么要有它
 *  ------------
 *  原来 `jpeg_quant_zz` 里是：
 *      wire [20:0] rc = recip_of(i_qt_data);          // 内含 22bit / 9bit 组合除法
 *  这条路径在布线报告里是编码器的**最差路径**：
 *      X_jpeg_qt 异步读 -> u_quant 量化乘加 = 21.9ns  => fmax 45.06MHz
 *  也就是说：编码器不管逻辑多少，只要这个除法器在编码器时钟域里，
 *  时钟就上不去 46MHz 以上 —— 而双目 60fps 需要每个引擎 ~146MHz。
 *
 *  做法
 *  ----
 *  把 `(2^21 + q) / (2q)`（整数 floor，与 round(2^20/q) 完全等价，见下）
 *  展开成 **22 级恢复余数长除法流水线**：
 *      * 吞吐 1 项/拍（和原来一样，装载 128 项仍只要 ~150 拍）
 *      * 延迟 23 拍（编码器装载状态机已经在 L_TAIL 等一拍，改成等 23 拍）
 *      * 每级只有 1 个 10bit 比较 + 1 个 10bit 减法 => 关键路径 ~2ns 量级
 *  这样编码器时钟域里不再有任何除法器。
 *
 *  数值等价性（关键，不能改成 (2^20+Q/2)/Q）
 *  -----------------------------------------
 *      round(2^20/Q) == (2^21 + Q) / (2*Q)     (整数 floor 除法)
 *  反例: Q=7 时 2^20/7 = 149796.571 -> round = 149797
 *        而 (2^20+3)/7 = 149796.99 -> floor = 149796 (差 1)
 *  本模块用**同一表达式**做长除法，所以与 `jpeg_quant_zz.recip_of` 逐位一致
 *  （`tb_jpeg_recip.v` 穷举 256 个 Q 值验证）。
 *
 *  Q=0 的处理也与原实现一致：按 1 处理。
 *===========================================================================*/
`timescale 1ns/1ps

module jpeg_recip_pipe (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_valid,     // 每拍一项
    input  wire [7:0]  i_q,         // 量化步长 Q
    output wire        o_valid,     // i_valid 之后 23 拍
    output wire [20:0] o_recip      // = round(2^20 / Q)
);

    localparam integer ITER = 22;   // 22 位被除数

    // q==0 按 1 处理（与原 recip_of 一致）
    wire [8:0] q1 = (i_q == 8'd0) ? 9'd1 : {1'b0, i_q};
    wire [8:0] dv = q1 << 1;              // 除数 D = 2*q1 (<=510, 9bit)
    wire [9:0] dvp = {1'b0, dv};          // 补齐到 10bit 便于比较/相减
    wire [21:0] num = 22'd2097152 + {13'd0, q1};   // 被除数 N = 2^21 + q1

    //------------------------------------------------------------------
    //  级 0: 输入寄存
    //------------------------------------------------------------------
    reg  [21:0] n_sr [0:ITER];   // 被除数移位链
    reg  [ 9:0] rem  [0:ITER];   // 余数
    reg  [21:0] quo  [0:ITER];   // 商
    reg  [ 9:0] d_sr [0:ITER];   // ★ 除数必须随项传递 (连发时每项 Q 不同)
    reg         vld  [0:ITER];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_sr[0] <= 22'd0;
            rem[0]  <= 10'd0;
            quo[0]  <= 22'd0;
            d_sr[0] <= 10'd0;
            vld[0]  <= 1'b0;
        end else begin
            n_sr[0] <= num;
            rem[0]  <= 10'd0;
            quo[0]  <= 22'd0;
            d_sr[0] <= dvp;
            vld[0]  <= i_valid;
        end
    end

    //------------------------------------------------------------------
    //  级 1..ITER: 每级取被除数最高位, 试减一次
    //------------------------------------------------------------------
    genvar k;
    generate
    for (k = 0; k < ITER; k = k + 1) begin : g_stage
        wire [9:0] sh = {rem[k][8:0], n_sr[k][21]};   // 余数左移并带入下一位
        wire       ge = (sh >= d_sr[k]);
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                rem[k+1] <= 10'd0;
                quo[k+1] <= 22'd0;
                n_sr[k+1] <= 22'd0;
                d_sr[k+1] <= 10'd0;
                vld[k+1] <= 1'b0;
            end else begin
                rem[k+1] <= ge ? (sh - d_sr[k]) : sh;
                quo[k+1] <= {quo[k][20:0], ge};
                n_sr[k+1] <= {n_sr[k][20:0], 1'b0};
                d_sr[k+1] <= d_sr[k];
                vld[k+1] <= vld[k];
            end
        end
    end
    endgenerate

    assign o_valid = vld[ITER];
    assign o_recip = quo[ITER][20:0];

endmodule
