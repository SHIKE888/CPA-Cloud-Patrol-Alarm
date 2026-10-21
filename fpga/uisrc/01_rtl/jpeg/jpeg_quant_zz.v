/*===========================================================================
 * Filename     : jpeg_quant_zz.v
 * Description  : 量化 + zigzag 重排
 *
 *  参考实现 (jpeg_ref.py):
 *      recip[i] = round(2^20 / Q[i])
 *      qf = (|F| * recip[i] + 2^19) >>> 20,  负数取 -qf
 *
 *  为什么用倒数乘法:
 *      8 个系数并行量化, 若用除法就要 8 个除法器; 倒数只需 8 个乘法器。
 *      recip 表每帧(或每次 Q 变化)重算一次, 128 拍/帧, 可忽略。
 *
 *  ★ recip 的整数等价式 (关键, 不能用 (2^20 + Q/2)/Q):
 *      round(2^20/Q) == (2^21 + Q) / (2*Q)      (整数 floor 除法)
 *    反例: Q=7 时 2^20/7 = 149796.571 -> round 应为 149797,
 *          而 (2^20 + 3)/7 = 149796.99 -> floor = 149796, 差 1。
 *    该差异会直接改变量化系数, 破坏与 jpeg_ref.py 的逐字节一致。
 *
 *  zigzag:
 *      DCT 每拍输出 8 个 F[k][t] (k=0..7), 自然序 nat = k*8+t。
 *      zigzag 位置 z = INV_ZIGZAG[nat]。由于 zigzag 是双射, 每个 qzz[n]
 *      只有唯一的数据源 (k) 和唯一的触发拍 (t), 所以写入只需 64 个
 *      "t 比较 + 固定数据源", 完全不需要数据 mux 和 RAM。
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_quant_zz (
    input  wire         clk,
    input  wire         rst_n,

    // ---------------- Q 表装载 (128 拍) ----------------
    input  wire         i_load,         // 脉冲: 开始重算 recip
    output reg  [6:0]   o_qt_idx,       // 送 jpeg_qtable_ram 读口 B
    input  wire [7:0]   i_qt_data,      // 晚 o_qt_idx 一拍
    output reg          o_load_done,

    // ---------------- 量化 (8 拍 / 块) ----------------
    input  wire         i_valid,
    input  wire [143:0] i_col,          // 8 x 18bit signed, F[0..7][t]
    input  wire [2:0]   i_t,            // 当前是第几行 (0..7)
    input  wire         i_chroma,       // 0 = 亮度表, 1 = 色度表
    output wire         o_wr,           // = i_valid
    output reg          o_blk_done,

    // ---------------- 顺序读出 (zigzag 序) ----------------
    input  wire [5:0]   i_rd_idx,
    output wire [15:0]  o_rd_data,
    // ★ 2026-10-21 为 60fps 加: 同一拍再给出 zigzag 下一个位置的系数。
    //   熵编码器有了一对系数就能一次出 2 个符号。
    output wire [15:0]  o_rd_data_n,
    // ★ 非零位图: bit[z]=1 表示 zigzag 位置 z 的量化为非零。
    //   熵编码器用它 + 优先编码器一拍跳过整段零系数 —— 原来扫零是 1 拍/个,
    //   一个 8x8 block 无论多稀疏都要 64 拍, 这才是 421 clk/MCU 的主因。
    output wire [63:0]  o_nz_mask
);

    //=============================================================== recip 表
    reg [20:0] rz_y [0:63];
    reg [20:0] rz_c [0:63];

    integer ri;
    initial begin
        for (ri = 0; ri < 64; ri = ri + 1) begin
            rz_y[ri] = 21'd0;
            rz_c[ri] = 21'd0;
        end
    end

    // round(2^20 / Q), Q >= 1
    function [20:0] recip_of;
        input [7:0] q;
        reg   [8:0] q1;
        reg   [21:0] num;
        begin
            q1  = (q == 8'd0) ? 9'd1 : {1'b0, q};
            num = 22'd2097152 + {13'd0, q1};
            recip_of = num / ({1'b0, q1} * 9'd2);
        end
    endfunction

    //=============================================================== 装载状态机
    localparam [1:0] L_IDLE = 2'd0;
    localparam [1:0] L_RUN  = 2'd1;
    localparam [1:0] L_TAIL = 2'd2;

    reg [1:0] lstate;
    reg [7:0] lidx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lstate      <= L_IDLE;
            lidx        <= 8'd0;
            o_qt_idx    <= 7'd0;
            o_load_done <= 1'b0;
        end else begin
            o_load_done <= 1'b0;
            case (lstate)
            L_IDLE: begin
                if (i_load) begin
                    lidx     <= 8'd0;
                    o_qt_idx <= 7'd0;
                    lstate   <= L_RUN;
                end
            end
            L_RUN: begin
                if (lidx == 8'd127) begin
                    lstate <= L_TAIL;
                end else begin
                    lidx     <= lidx + 8'd1;
                    o_qt_idx <= lidx[6:0] + 7'd1;
                end
            end
            L_TAIL: begin
                // 收最后一个数据 (i_qt_data 仍对应 idx=127)
                o_load_done <= 1'b1;
                lstate      <= L_IDLE;
            end
            default: lstate <= L_IDLE;
            endcase
        end
    end

    // 数据比地址晚一拍: 当前拍收到的 i_qt_data 对应上一拍的 o_qt_idx
    // 用一个拍延迟的 idx 来定位写入
    reg [6:0] widx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) widx <= 7'd0;
        else        widx <= o_qt_idx;
    end

    wire [20:0] rc = recip_of(i_qt_data);
    wire        wr_y = (lstate == L_RUN) && (widx <= 7'd63);
    wire        wr_c = (lstate == L_RUN) && (widx >  7'd63) && (widx <= 7'd127);

    always @(posedge clk) begin
        if (wr_y) rz_y[widx[5:0]] <= rc;
        if (wr_c) rz_c[widx[5:0]] <= rc;
    end

    //=============================================================== 量化
    wire [20:0] rq [0:7];

    genvar gk;
    generate
    for (gk = 0; gk < 8; gk = gk + 1) begin : g_rq
        assign rq[gk] = i_chroma ? rz_c[gk*8 + i_t]
                                 : rz_y[gk*8 + i_t];
    end
    endgenerate

    wire signed [17:0] f   [0:7];
    wire        [17:0] mag [0:7];
    wire        [38:0] prod[0:7];
    wire signed [15:0] qres[0:7];

    genvar gq;
    generate
    for (gq = 0; gq < 8; gq = gq + 1) begin : g_q
        assign f[gq]    = i_col[gq*18 +: 18];
        assign mag[gq]  = f[gq][17] ? (-f[gq]) : f[gq];
        assign prod[gq] = (mag[gq] * rq[gq]) + 39'd524288;      // + 2^19
        assign qres[gq] = f[gq][17] ? (-(prod[gq] >> 20))
                                    :  ( prod[gq] >> 20);
    end
    endgenerate

    assign o_wr = i_valid;

    //=============================================================== zigzag 结果寄存器
    reg [15:0] qzz [0:63];

    integer m;
    integer qi;
    initial begin
        for (qi = 0; qi < 64; qi = qi + 1) qzz[qi] = 16'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_blk_done <= 1'b0;
        end else begin
            o_blk_done <= i_valid && (i_t == 3'd7);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (m = 0; m < 64; m = m + 1) qzz[m] <= 16'd0;
        end else if (i_valid) begin
            qzz[ 0] <= (i_t == 3'd0) ? qres[0] : qzz[ 0];   // nat= 0
            qzz[ 1] <= (i_t == 3'd1) ? qres[0] : qzz[ 1];   // nat= 1
            qzz[ 2] <= (i_t == 3'd0) ? qres[1] : qzz[ 2];   // nat= 8
            qzz[ 3] <= (i_t == 3'd0) ? qres[2] : qzz[ 3];   // nat=16
            qzz[ 4] <= (i_t == 3'd1) ? qres[1] : qzz[ 4];   // nat= 9
            qzz[ 5] <= (i_t == 3'd2) ? qres[0] : qzz[ 5];   // nat= 2
            qzz[ 6] <= (i_t == 3'd3) ? qres[0] : qzz[ 6];   // nat= 3
            qzz[ 7] <= (i_t == 3'd2) ? qres[1] : qzz[ 7];   // nat=10
            qzz[ 8] <= (i_t == 3'd1) ? qres[2] : qzz[ 8];   // nat=17
            qzz[ 9] <= (i_t == 3'd0) ? qres[3] : qzz[ 9];   // nat=24
            qzz[10] <= (i_t == 3'd0) ? qres[4] : qzz[10];   // nat=32
            qzz[11] <= (i_t == 3'd1) ? qres[3] : qzz[11];   // nat=25
            qzz[12] <= (i_t == 3'd2) ? qres[2] : qzz[12];   // nat=18
            qzz[13] <= (i_t == 3'd3) ? qres[1] : qzz[13];   // nat=11
            qzz[14] <= (i_t == 3'd4) ? qres[0] : qzz[14];   // nat= 4
            qzz[15] <= (i_t == 3'd5) ? qres[0] : qzz[15];   // nat= 5
            qzz[16] <= (i_t == 3'd4) ? qres[1] : qzz[16];   // nat=12
            qzz[17] <= (i_t == 3'd3) ? qres[2] : qzz[17];   // nat=19
            qzz[18] <= (i_t == 3'd2) ? qres[3] : qzz[18];   // nat=26
            qzz[19] <= (i_t == 3'd1) ? qres[4] : qzz[19];   // nat=33
            qzz[20] <= (i_t == 3'd0) ? qres[5] : qzz[20];   // nat=40
            qzz[21] <= (i_t == 3'd0) ? qres[6] : qzz[21];   // nat=48
            qzz[22] <= (i_t == 3'd1) ? qres[5] : qzz[22];   // nat=41
            qzz[23] <= (i_t == 3'd2) ? qres[4] : qzz[23];   // nat=34
            qzz[24] <= (i_t == 3'd3) ? qres[3] : qzz[24];   // nat=27
            qzz[25] <= (i_t == 3'd4) ? qres[2] : qzz[25];   // nat=20
            qzz[26] <= (i_t == 3'd5) ? qres[1] : qzz[26];   // nat=13
            qzz[27] <= (i_t == 3'd6) ? qres[0] : qzz[27];   // nat= 6
            qzz[28] <= (i_t == 3'd7) ? qres[0] : qzz[28];   // nat= 7
            qzz[29] <= (i_t == 3'd6) ? qres[1] : qzz[29];   // nat=14
            qzz[30] <= (i_t == 3'd5) ? qres[2] : qzz[30];   // nat=21
            qzz[31] <= (i_t == 3'd4) ? qres[3] : qzz[31];   // nat=28
            qzz[32] <= (i_t == 3'd3) ? qres[4] : qzz[32];   // nat=35
            qzz[33] <= (i_t == 3'd2) ? qres[5] : qzz[33];   // nat=42
            qzz[34] <= (i_t == 3'd1) ? qres[6] : qzz[34];   // nat=49
            qzz[35] <= (i_t == 3'd0) ? qres[7] : qzz[35];   // nat=56
            qzz[36] <= (i_t == 3'd1) ? qres[7] : qzz[36];   // nat=57
            qzz[37] <= (i_t == 3'd2) ? qres[6] : qzz[37];   // nat=50
            qzz[38] <= (i_t == 3'd3) ? qres[5] : qzz[38];   // nat=43
            qzz[39] <= (i_t == 3'd4) ? qres[4] : qzz[39];   // nat=36
            qzz[40] <= (i_t == 3'd5) ? qres[3] : qzz[40];   // nat=29
            qzz[41] <= (i_t == 3'd6) ? qres[2] : qzz[41];   // nat=22
            qzz[42] <= (i_t == 3'd7) ? qres[1] : qzz[42];   // nat=15
            qzz[43] <= (i_t == 3'd7) ? qres[2] : qzz[43];   // nat=23
            qzz[44] <= (i_t == 3'd6) ? qres[3] : qzz[44];   // nat=30
            qzz[45] <= (i_t == 3'd5) ? qres[4] : qzz[45];   // nat=37
            qzz[46] <= (i_t == 3'd4) ? qres[5] : qzz[46];   // nat=44
            qzz[47] <= (i_t == 3'd3) ? qres[6] : qzz[47];   // nat=51
            qzz[48] <= (i_t == 3'd2) ? qres[7] : qzz[48];   // nat=58
            qzz[49] <= (i_t == 3'd3) ? qres[7] : qzz[49];   // nat=59
            qzz[50] <= (i_t == 3'd4) ? qres[6] : qzz[50];   // nat=52
            qzz[51] <= (i_t == 3'd5) ? qres[5] : qzz[51];   // nat=45
            qzz[52] <= (i_t == 3'd6) ? qres[4] : qzz[52];   // nat=38
            qzz[53] <= (i_t == 3'd7) ? qres[3] : qzz[53];   // nat=31
            qzz[54] <= (i_t == 3'd7) ? qres[4] : qzz[54];   // nat=39
            qzz[55] <= (i_t == 3'd6) ? qres[5] : qzz[55];   // nat=46
            qzz[56] <= (i_t == 3'd5) ? qres[6] : qzz[56];   // nat=53
            qzz[57] <= (i_t == 3'd4) ? qres[7] : qzz[57];   // nat=60
            qzz[58] <= (i_t == 3'd5) ? qres[7] : qzz[58];   // nat=61
            qzz[59] <= (i_t == 3'd6) ? qres[6] : qzz[59];   // nat=54
            qzz[60] <= (i_t == 3'd7) ? qres[5] : qzz[60];   // nat=47
            qzz[61] <= (i_t == 3'd7) ? qres[6] : qzz[61];   // nat=55
            qzz[62] <= (i_t == 3'd6) ? qres[7] : qzz[62];   // nat=62
            qzz[63] <= (i_t == 3'd7) ? qres[7] : qzz[63];   // nat=63
        end
    end

    assign o_rd_data = qzz[i_rd_idx];
    // kk==63 时没有下一个, 返回 0 (会被当零系数跳过)
    assign o_rd_data_n = (i_rd_idx == 6'd63) ? 16'd0 : qzz[i_rd_idx + 6'd1];

    genvar gz;
    generate
        for (gz = 0; gz < 64; gz = gz + 1) begin : g_nz
            assign o_nz_mask[gz] = (qzz[gz] != 16'sd0);
        end
    endgenerate

endmodule
