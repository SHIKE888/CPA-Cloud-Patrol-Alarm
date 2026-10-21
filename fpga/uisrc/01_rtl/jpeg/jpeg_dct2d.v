/*===========================================================================
 * Filename     : jpeg_dct2d.v
 * Description  : 8x8 定点 2D DCT (与 tools/jpeg_ref.py 的 fdct_blocks 逐位一致)
 *
 *  参考算法 (jpeg_ref.py):
 *      B[k][n] = round( c(k) * cos((2n+1)k*pi/16) * 2^15 ),  c(0)=1/sqrt2, c(k>0)=1
 *      pass1 (沿 y):  G[k][u] = ( sum_v B[k][v]*blk[v][u] + 2^14 ) >>> 15
 *      pass2 (沿 x):  F[k][v] = ( sum_u B[v][u]*G[k][u] + 2^14 ) >>> 15
 *      F = (F + 2) >>> 2
 *
 *  ★ 关键前提: B 的奇偶对称性是【精确】的 (已用 Python 逐对核对 32 对)
 *      B[k][n] ==  B[k][7-n]  (k 偶)      B[k][n] == -B[k][7-n]  (k 奇)
 *    因此 1D 变换只需 4 次乘法:
 *      k 偶: out = B[k][0]*(x0+x7) + B[k][1]*(x1+x6)
 *                + B[k][2]*(x2+x5) + B[k][3]*(x3+x4)
 *      k 奇: out = B[k][0]*(x0-x7) + B[k][1]*(x1-x6)
 *                + B[k][2]*(x2-x5) + B[k][3]*(x3-x4)
 *
 *  时序 (NENG=8, 每块 30 拍; 一个 MCU = 4 块 = 120 拍):
 *      S_LOAD  8 拍   每拍收一行 (8 个像素)
 *      S_P1    8 拍   每拍发 k=0..7, 8 个引擎并行算 8 列
 *      S_P1F   3 拍   等流水写回 G (最后一拍 k=7 要 3 拍才落到 G)
 *      S_P2    8 拍   每拍发 v=0..7, 8 个引擎并行算 8 行
 *      S_P2F   3 拍   等最后一拍输出
 *  1080p60 预算 152 clk/MCU -> 120 拍, 余量 1.27x
 *
 *  流水: S1 乘法 -> S2 (p0+p1),(p2+p3) -> S3 求和 -> S4 舍入/移位
 *        v1/v2/v3 与 k1/k2/k3、q1/q2/q3 三条影子链保证写地址与数据同拍
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_dct2d #(
    parameter integer NENG = 8          // 并行 1D 引擎数 (8: 120clk/MCU, 4: 240clk/MCU)
) (
    input  wire         clk,
    input  wire         rst_n,

    // ---- 输入: 一块 8x8, 每拍喂一行 8 个像素, 连续 8 拍 ----
    input  wire         i_start,        // 脉冲: 开始接收
    input  wire         i_valid,        // i_row 有效
    input  wire [127:0] i_row,          // 8 x 16bit signed, {x7,...,x0}
    output wire         i_ready,        // IDLE 时才为 1

    output reg          o_busy,

    // ---- 输出: 每拍一行 (8 个系数), 连续 8 拍 ----
    output reg          o_valid,
    output reg  [143:0] o_col,          // 8 x 18bit signed, {F[7][t],...,F[0][t]}
    output reg          o_done
);

    `undef JPEG_DEFS_VH
    `include "jpeg_defs.vh"

    //=============================================================== 基矩阵常数
    function signed [17:0] bcoef;
        input [2:0] k;
        input [1:0] n;
        reg signed [17:0] t;
        begin
            t = 18'sd0;
            case (k)
            3'd0: t = 18'sd23170;                                   // 8 项全同
            3'd1: case (n)
                  2'd0: t =  18'sd32138;
                  2'd1: t =  18'sd27246;
                  2'd2: t =  18'sd18205;
                  default: t = 18'sd6393;   endcase
            3'd2: case (n)
                  2'd0: t =  18'sd30274;
                  2'd1: t =  18'sd12540;
                  2'd2: t = -18'sd12540;
                  default: t = -18'sd30274; endcase
            3'd3: case (n)
                  2'd0: t =  18'sd27246;
                  2'd1: t = -18'sd6393;
                  2'd2: t = -18'sd32138;
                  default: t = -18'sd18205; endcase
            3'd4: case (n)
                  2'd0: t =  18'sd23170;
                  2'd1: t = -18'sd23170;
                  2'd2: t = -18'sd23170;
                  default: t = 18'sd23170;  endcase
            3'd5: case (n)
                  2'd0: t =  18'sd18205;
                  2'd1: t = -18'sd32138;
                  2'd2: t =  18'sd6393;
                  default: t = 18'sd27246;  endcase
            3'd6: case (n)
                  2'd0: t =  18'sd12540;
                  2'd1: t = -18'sd30274;
                  2'd2: t =  18'sd30274;
                  default: t = -18'sd12540; endcase
            3'd7: case (n)
                  2'd0: t =  18'sd6393;
                  2'd1: t = -18'sd18205;
                  2'd2: t =  18'sd27246;
                  default: t = -18'sd32138; endcase
            endcase
            bcoef = t;
        end
    endfunction

    //=============================================================== 状态
    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_LOAD = 3'd1;
    localparam [2:0] S_P1   = 3'd2;
    localparam [2:0] S_P1F  = 3'd3;
    localparam [2:0] S_P2   = 3'd4;
    localparam [2:0] S_P2F  = 3'd5;

    reg [2:0] state;
    reg [2:0] lcnt;
    reg [1:0] fcnt;
    reg       pass2_r;

    assign i_ready = (state == S_IDLE);

    //=============================================================== 存储
    reg signed [15:0] blk [0:63];   // 输入块 [v*8+u]
    reg signed [15:0] G   [0:63];   // pass1  [k*8+u]
    reg signed [17:0] F   [0:63];   // pass2  [k*8+v]

    // 仿真初始化 (综合时 FF/BRAM 也有上电值, 不依赖此块)
    integer mi;
    initial begin
        for (mi = 0; mi < 64; mi = mi + 1) begin
            blk[mi] = 16'sd0;
            G[mi]   = 16'sd0;
            F[mi]   = 18'sd0;
        end
    end

    //=============================================================== S1: 对称化 + 4 乘法
    wire [2:0] kk = lcnt;

    wire signed [17:0] c0 = bcoef(kk, 2'd0);
    wire signed [17:0] c1 = bcoef(kk, 2'd1);
    wire signed [17:0] c2 = bcoef(kk, 2'd2);
    wire signed [17:0] c3 = bcoef(kk, 2'd3);
    wire               even_k = ~kk[0];

    wire signed [35:0] pr [0:(NENG*4)-1];

    // ★ 用 generate + assign, 不要用 always@(*) + reg 中间量:
    //   always@(*) 里的中间 reg (sx) 会被当成"被赋值变量", 敏感表推断时
    //   容易漏掉 blk/G 的数组元素, 导致 pr 不更新 -> s01 保持 X -> 整个码流报废。
    genvar ge;
    generate
    for (ge = 0; ge < NENG; ge = ge + 1) begin : g_eng
        wire signed [16:0] x0 = pass2_r ? G[ge*8+0] : blk[0*8+ge];
        wire signed [16:0] x1 = pass2_r ? G[ge*8+1] : blk[1*8+ge];
        wire signed [16:0] x2 = pass2_r ? G[ge*8+2] : blk[2*8+ge];
        wire signed [16:0] x3 = pass2_r ? G[ge*8+3] : blk[3*8+ge];
        wire signed [16:0] x4 = pass2_r ? G[ge*8+4] : blk[4*8+ge];
        wire signed [16:0] x5 = pass2_r ? G[ge*8+5] : blk[5*8+ge];
        wire signed [16:0] x6 = pass2_r ? G[ge*8+6] : blk[6*8+ge];
        wire signed [16:0] x7 = pass2_r ? G[ge*8+7] : blk[7*8+ge];

        wire signed [16:0] e0 = even_k ? (x0 + x7) : (x0 - x7);
        wire signed [16:0] e1 = even_k ? (x1 + x6) : (x1 - x6);
        wire signed [16:0] e2 = even_k ? (x2 + x5) : (x2 - x5);
        wire signed [16:0] e3 = even_k ? (x3 + x4) : (x3 - x4);

        assign pr[ge*4+0] = e0 * c0;
        assign pr[ge*4+1] = e1 * c1;
        assign pr[ge*4+2] = e2 * c2;
        assign pr[ge*4+3] = e3 * c3;
    end
    endgenerate

    //=============================================================== 流水影子链
    //
    //  ⚠ 对齐关系 (踩过一次):
    //    拍 t   : kk=k, pr 用 blk/G 当前值
    //    拍 t+1 : a01/a23 = pr(t) 的两两和
    //    拍 t+2 : s01 = a01(t+1)+a23(t+1) = 四项和(t)     <- 数据延迟 2 拍
    //    k2 也是"拍 t+2 拿到 kk(t)" —— 2 拍延迟, 与 s01 同拍 ✓
    //    若再用一级 k3 (3 拍), 就会整体错开一个频率点, 表现为
    //    got[k][t] == exp[k+1][t] (已实测)
    reg               v1, v2;
    reg [2:0]         k1, k2;
    reg               q1, q2;           // 1 = pass2
    reg signed [36:0] a01 [0:7];
    reg signed [36:0] a23 [0:7];
    reg signed [37:0] s01 [0:7];

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; v2 <= 1'b0;
            k1 <= 3'd0; k2 <= 3'd0;
            q1 <= 1'b0; q2 <= 1'b0;
            for (j = 0; j < 8; j = j + 1) begin
                a01[j] <= 37'sd0;
                a23[j] <= 37'sd0;
                s01[j] <= 38'sd0;
            end
        end else begin
            v1 <= ((state == S_P1) || (state == S_P2));
            k1 <= kk;
            q1 <= pass2_r;
            for (j = 0; j < NENG; j = j + 1) begin
                a01[j] <= pr[j*4+0] + pr[j*4+1];
                a23[j] <= pr[j*4+2] + pr[j*4+3];
                s01[j] <= a01[j] + a23[j];
            end
            v2 <= v1;  k2 <= k1;  q2 <= q1;
        end
    end

    //=============================================================== S4: 舍入 + 写回 / 输出
    //   pass1: G[k][u] = (acc + 2^14) >>> 15
    //   pass2: F[k][v] = (((acc + 2^14) >>> 15) + 2) >>> 2
    wire signed [37:0] rnd = 38'sd16384;

    integer m;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid <= 1'b0;
            o_done  <= 1'b0;
            o_col   <= 144'd0;
            for (m = 0; m < 64; m = m + 1) begin
                G[m] <= 16'sd0;
                F[m] <= 18'sd0;
            end
        end else begin
            o_valid <= 1'b0;
            o_done  <= 1'b0;
            if (v2) begin
                for (m = 0; m < NENG; m = m + 1) begin
                    if (!q2) begin
                        G[k2*8 + m] <= (s01[m] + rnd) >>> 15;
                    end else begin
                        F[k2*8 + m] <= (((s01[m] + rnd) >>> 15) + 38'sd2) >>> 2;
                        o_col[m*18 +: 18] <= (((s01[m] + rnd) >>> 15) + 38'sd2) >>> 2;
                    end
                end
                if (q2) begin
                    o_valid <= 1'b1;
                    if (k2 == 3'd7) o_done <= 1'b1;
                end
            end
        end
    end

    //=============================================================== 主状态机
    integer q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            lcnt    <= 3'd0;
            fcnt    <= 2'd0;
            pass2_r <= 1'b0;
            o_busy  <= 1'b0;
        end else begin
            case (state)
            S_IDLE: begin
                o_busy  <= 1'b0;
                lcnt    <= 3'd0;
                fcnt    <= 2'd0;
                pass2_r <= 1'b0;
                if (i_start) begin
                    // 只置状态, 不采样数据 —— RAM 读有 1 拍延迟,
                    // 上游在 i_start 同拍摆地址, 下一拍(S_LOAD 第 0 拍)正好收到第 0 行
                    lcnt   <= 3'd0;
                    o_busy <= 1'b1;
                    state  <= S_LOAD;
                end
            end

            //------------------------------------------------- 装填 8 拍
            S_LOAD: begin
                if (i_valid) begin
                    for (q = 0; q < 8; q = q + 1)
                        blk[lcnt*8 + q] <= i_row[q*16 +: 16];
                    if (lcnt == 3'd7) begin
                        lcnt    <= 3'd0;
                        pass2_r <= 1'b0;
                        state   <= S_P1;
                    end else begin
                        lcnt <= lcnt + 3'd1;
                    end
                end
            end

            //------------------------------------------------- pass1 发 8 拍
            S_P1: begin
                pass2_r <= 1'b0;
                if (lcnt == 3'd7) begin
                    lcnt  <= 3'd0;
                    fcnt  <= 2'd0;
                    state <= S_P1F;
                end else begin
                    lcnt <= lcnt + 3'd1;
                end
            end

            //------------------------------------------------- 等 G 写回 (3 拍)
            S_P1F: begin
                if (fcnt == 2'd2) begin
                    fcnt    <= 2'd0;
                    lcnt    <= 3'd0;
                    pass2_r <= 1'b1;
                    state   <= S_P2;
                end else begin
                    fcnt <= fcnt + 2'd1;
                end
            end

            //------------------------------------------------- pass2 发 8 拍
            S_P2: begin
                pass2_r <= 1'b1;
                if (lcnt == 3'd7) begin
                    lcnt  <= 3'd0;
                    fcnt  <= 2'd0;
                    state <= S_P2F;
                end else begin
                    lcnt <= lcnt + 3'd1;
                end
            end

            //------------------------------------------------- 等输出排空 (3 拍)
            S_P2F: begin
                if (fcnt == 2'd2) begin
                    fcnt  <= 2'd0;
                    state <= S_IDLE;
                end else begin
                    fcnt <= fcnt + 2'd1;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
