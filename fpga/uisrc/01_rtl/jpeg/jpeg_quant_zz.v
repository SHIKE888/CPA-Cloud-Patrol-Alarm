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
    // ★ 2026-10-21 双缓冲 (block 级流水): DCT 写其中一组时, 熵编码器读另一组,
    //   这样 DCT(30 拍) 与熵编码(跳零后 ~22 拍) 可以完全重叠。
    //   不自缓冲时 208 clk/MCU = 4 x (10 读行 + 20 DCT 尾 + 22 熵), 仍够不着
    //   1080p60 的 151.7 预算。
    input  wire         i_wr_buf,
    input  wire         i_rd_buf,
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
    localparam [1:0] L_DRAIN= 2'd2;   // ★ 等倒数流水排空 (23 拍)
    localparam [1:0] L_TAIL = 2'd3;

    localparam integer RCP_LAT = 23;  // jpeg_recip_pipe 的延迟 (拍)

    reg [1:0] lstate;
    reg [7:0] lidx;
    reg [4:0] drain;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lstate      <= L_IDLE;
            lidx        <= 8'd0;
            drain       <= 5'd0;
            o_qt_idx    <= 7'd0;
            o_load_done <= 1'b0;
        end else begin
            o_load_done <= 1'b0;
            case (lstate)
            L_IDLE: begin
                if (i_load) begin
                    lidx     <= 8'd0;
                    drain    <= 5'd0;
                    o_qt_idx <= 7'd0;
                    lstate   <= L_RUN;
                end
            end
            L_RUN: begin
                if (lidx == 8'd127) begin
                    lstate <= L_DRAIN;      // 最后一个数据已进流水, 等排空
                end else begin
                    lidx     <= lidx + 8'd1;
                    o_qt_idx <= lidx[6:0] + 7'd1;
                end
            end
            L_DRAIN: begin
                if (drain >= (RCP_LAT)) begin
                    lstate <= L_TAIL;
                end else begin
                    drain <= drain + 5'd1;
                end
            end
            L_TAIL: begin
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

    //=========================================================================
    //  倒数表装载: ★ 不再用组合除法器 (它是编码器的最差路径 21.9ns => fmax
    //  45MHz)。现在走 jpeg_recip_pipe 的 22 级流水长除法:
    //      1 项/拍吞吐 (装载仍是 ~150 拍), 延迟 RCP_LAT 拍
    //  数值与原来的 recip_of 逐位一致 (tb_jpeg_recip 已穷举 256 个 Q 验证)。
    //=========================================================================
    wire        rc_vld;
    wire [20:0] rc;

    jpeg_recip_pipe u_recip (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_valid (lstate == L_RUN),   // i_qt_data 在本拍有效
        .i_q     (i_qt_data),
        .o_valid (rc_vld),
        .o_recip (rc)
    );

    // 写地址要跟着 rc 一起延后 RCP_LAT 拍
    reg [6:0] widx_pipe [0:RCP_LAT-1];
    integer wi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (wi = 0; wi < RCP_LAT; wi = wi + 1) widx_pipe[wi] <= 7'd0;
        end else begin
            widx_pipe[0] <= widx;
            for (wi = 1; wi < RCP_LAT; wi = wi + 1) widx_pipe[wi] <= widx_pipe[wi-1];
        end
    end

    wire [6:0] widx_d = widx_pipe[RCP_LAT-1];
    // ⚠ 与改造前行为一致: 只有 L_RUN 期间的 127 项会写入 (rc_vld 已编码该条件),
    //   idx=127 那一项依旧不写 —— 这是历史行为, 改变会破坏逐字节回归。
    wire        wr_y = rc_vld && (widx_d <= 7'd63);
    wire        wr_c = rc_vld && (widx_d >  7'd63);

    always @(posedge clk) begin
        if (wr_y) rz_y[widx_d[5:0]] <= rc;
        if (wr_c) rz_c[widx_d[5:0]] <= rc;
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
    reg [15:0] qzz [0:127];
    // 双缓冲写入地址: 0 或 64
    wire [6:0] wo = {i_wr_buf, 6'd0};

    integer m;
    integer qi;
    initial begin
        for (qi = 0; qi < 128; qi = qi + 1) qzz[qi] = 16'd0;
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
            for (m = 0; m < 128; m = m + 1) qzz[m] <= 16'd0;
        end else if (i_valid) begin
            qzz[wo + 6'd0] <= (i_t == 3'd0) ? qres[0] : qzz[wo + 6'd0];   // nat= 0
            qzz[wo + 6'd1] <= (i_t == 3'd1) ? qres[0] : qzz[wo + 6'd1];   // nat= 1
            qzz[wo + 6'd2] <= (i_t == 3'd0) ? qres[1] : qzz[wo + 6'd2];   // nat= 8
            qzz[wo + 6'd3] <= (i_t == 3'd0) ? qres[2] : qzz[wo + 6'd3];   // nat=16
            qzz[wo + 6'd4] <= (i_t == 3'd1) ? qres[1] : qzz[wo + 6'd4];   // nat= 9
            qzz[wo + 6'd5] <= (i_t == 3'd2) ? qres[0] : qzz[wo + 6'd5];   // nat= 2
            qzz[wo + 6'd6] <= (i_t == 3'd3) ? qres[0] : qzz[wo + 6'd6];   // nat= 3
            qzz[wo + 6'd7] <= (i_t == 3'd2) ? qres[1] : qzz[wo + 6'd7];   // nat=10
            qzz[wo + 6'd8] <= (i_t == 3'd1) ? qres[2] : qzz[wo + 6'd8];   // nat=17
            qzz[wo + 6'd9] <= (i_t == 3'd0) ? qres[3] : qzz[wo + 6'd9];   // nat=24
            qzz[wo + 6'd10] <= (i_t == 3'd0) ? qres[4] : qzz[wo + 6'd10];   // nat=32
            qzz[wo + 6'd11] <= (i_t == 3'd1) ? qres[3] : qzz[wo + 6'd11];   // nat=25
            qzz[wo + 6'd12] <= (i_t == 3'd2) ? qres[2] : qzz[wo + 6'd12];   // nat=18
            qzz[wo + 6'd13] <= (i_t == 3'd3) ? qres[1] : qzz[wo + 6'd13];   // nat=11
            qzz[wo + 6'd14] <= (i_t == 3'd4) ? qres[0] : qzz[wo + 6'd14];   // nat= 4
            qzz[wo + 6'd15] <= (i_t == 3'd5) ? qres[0] : qzz[wo + 6'd15];   // nat= 5
            qzz[wo + 6'd16] <= (i_t == 3'd4) ? qres[1] : qzz[wo + 6'd16];   // nat=12
            qzz[wo + 6'd17] <= (i_t == 3'd3) ? qres[2] : qzz[wo + 6'd17];   // nat=19
            qzz[wo + 6'd18] <= (i_t == 3'd2) ? qres[3] : qzz[wo + 6'd18];   // nat=26
            qzz[wo + 6'd19] <= (i_t == 3'd1) ? qres[4] : qzz[wo + 6'd19];   // nat=33
            qzz[wo + 6'd20] <= (i_t == 3'd0) ? qres[5] : qzz[wo + 6'd20];   // nat=40
            qzz[wo + 6'd21] <= (i_t == 3'd0) ? qres[6] : qzz[wo + 6'd21];   // nat=48
            qzz[wo + 6'd22] <= (i_t == 3'd1) ? qres[5] : qzz[wo + 6'd22];   // nat=41
            qzz[wo + 6'd23] <= (i_t == 3'd2) ? qres[4] : qzz[wo + 6'd23];   // nat=34
            qzz[wo + 6'd24] <= (i_t == 3'd3) ? qres[3] : qzz[wo + 6'd24];   // nat=27
            qzz[wo + 6'd25] <= (i_t == 3'd4) ? qres[2] : qzz[wo + 6'd25];   // nat=20
            qzz[wo + 6'd26] <= (i_t == 3'd5) ? qres[1] : qzz[wo + 6'd26];   // nat=13
            qzz[wo + 6'd27] <= (i_t == 3'd6) ? qres[0] : qzz[wo + 6'd27];   // nat= 6
            qzz[wo + 6'd28] <= (i_t == 3'd7) ? qres[0] : qzz[wo + 6'd28];   // nat= 7
            qzz[wo + 6'd29] <= (i_t == 3'd6) ? qres[1] : qzz[wo + 6'd29];   // nat=14
            qzz[wo + 6'd30] <= (i_t == 3'd5) ? qres[2] : qzz[wo + 6'd30];   // nat=21
            qzz[wo + 6'd31] <= (i_t == 3'd4) ? qres[3] : qzz[wo + 6'd31];   // nat=28
            qzz[wo + 6'd32] <= (i_t == 3'd3) ? qres[4] : qzz[wo + 6'd32];   // nat=35
            qzz[wo + 6'd33] <= (i_t == 3'd2) ? qres[5] : qzz[wo + 6'd33];   // nat=42
            qzz[wo + 6'd34] <= (i_t == 3'd1) ? qres[6] : qzz[wo + 6'd34];   // nat=49
            qzz[wo + 6'd35] <= (i_t == 3'd0) ? qres[7] : qzz[wo + 6'd35];   // nat=56
            qzz[wo + 6'd36] <= (i_t == 3'd1) ? qres[7] : qzz[wo + 6'd36];   // nat=57
            qzz[wo + 6'd37] <= (i_t == 3'd2) ? qres[6] : qzz[wo + 6'd37];   // nat=50
            qzz[wo + 6'd38] <= (i_t == 3'd3) ? qres[5] : qzz[wo + 6'd38];   // nat=43
            qzz[wo + 6'd39] <= (i_t == 3'd4) ? qres[4] : qzz[wo + 6'd39];   // nat=36
            qzz[wo + 6'd40] <= (i_t == 3'd5) ? qres[3] : qzz[wo + 6'd40];   // nat=29
            qzz[wo + 6'd41] <= (i_t == 3'd6) ? qres[2] : qzz[wo + 6'd41];   // nat=22
            qzz[wo + 6'd42] <= (i_t == 3'd7) ? qres[1] : qzz[wo + 6'd42];   // nat=15
            qzz[wo + 6'd43] <= (i_t == 3'd7) ? qres[2] : qzz[wo + 6'd43];   // nat=23
            qzz[wo + 6'd44] <= (i_t == 3'd6) ? qres[3] : qzz[wo + 6'd44];   // nat=30
            qzz[wo + 6'd45] <= (i_t == 3'd5) ? qres[4] : qzz[wo + 6'd45];   // nat=37
            qzz[wo + 6'd46] <= (i_t == 3'd4) ? qres[5] : qzz[wo + 6'd46];   // nat=44
            qzz[wo + 6'd47] <= (i_t == 3'd3) ? qres[6] : qzz[wo + 6'd47];   // nat=51
            qzz[wo + 6'd48] <= (i_t == 3'd2) ? qres[7] : qzz[wo + 6'd48];   // nat=58
            qzz[wo + 6'd49] <= (i_t == 3'd3) ? qres[7] : qzz[wo + 6'd49];   // nat=59
            qzz[wo + 6'd50] <= (i_t == 3'd4) ? qres[6] : qzz[wo + 6'd50];   // nat=52
            qzz[wo + 6'd51] <= (i_t == 3'd5) ? qres[5] : qzz[wo + 6'd51];   // nat=45
            qzz[wo + 6'd52] <= (i_t == 3'd6) ? qres[4] : qzz[wo + 6'd52];   // nat=38
            qzz[wo + 6'd53] <= (i_t == 3'd7) ? qres[3] : qzz[wo + 6'd53];   // nat=31
            qzz[wo + 6'd54] <= (i_t == 3'd7) ? qres[4] : qzz[wo + 6'd54];   // nat=39
            qzz[wo + 6'd55] <= (i_t == 3'd6) ? qres[5] : qzz[wo + 6'd55];   // nat=46
            qzz[wo + 6'd56] <= (i_t == 3'd5) ? qres[6] : qzz[wo + 6'd56];   // nat=53
            qzz[wo + 6'd57] <= (i_t == 3'd4) ? qres[7] : qzz[wo + 6'd57];   // nat=60
            qzz[wo + 6'd58] <= (i_t == 3'd5) ? qres[7] : qzz[wo + 6'd58];   // nat=61
            qzz[wo + 6'd59] <= (i_t == 3'd6) ? qres[6] : qzz[wo + 6'd59];   // nat=54
            qzz[wo + 6'd60] <= (i_t == 3'd7) ? qres[5] : qzz[wo + 6'd60];   // nat=47
            qzz[wo + 6'd61] <= (i_t == 3'd7) ? qres[6] : qzz[wo + 6'd61];   // nat=55
            qzz[wo + 6'd62] <= (i_t == 3'd6) ? qres[7] : qzz[wo + 6'd62];   // nat=62
            qzz[wo + 6'd63] <= (i_t == 3'd7) ? qres[7] : qzz[wo + 6'd63];   // nat=63
        end
    end

    assign o_rd_data = qzz[{i_rd_buf, i_rd_idx}];
    // kk==63 时没有下一个, 返回 0 (会被当零系数跳过)
    assign o_rd_data_n = (i_rd_idx == 6'd63) ? 16'd0
                                            : qzz[{i_rd_buf, i_rd_idx + 6'd1}];

    genvar gz;
    wire [63:0] nz_mask_c;
    generate
        for (gz = 0; gz < 64; gz = gz + 1) begin : g_nz
            assign nz_mask_c[gz] = (qzz[wo + gz] != 16'sd0);
        end
    endgenerate

    // ★ 位图必须在**块结束时锁存**, 不能直接组合输出。
    //   qzz 是分 i_t=0..7 八个阶段写入的, i_t=7 那一拍的 posedge 之前,
    //   最后 8 项还是**上一个块**的值 —— 组合输出的位图会是新旧混合的中间态。
    //   双缓冲后两组位图各自独立锁存, 读侧按 i_rd_buf 选。
    //
    // ★★ 双缓冲特有陷阱: q_blk_done (i_t==7) 那一拍 wr_buf 同时也翻转了,
    //   所以下一拍 (q_done_d=1) 时 wo 已经指向**另一组**, 那一组的 qzz 还是
    //   上一轮的旧数据。原来直接用 nz_mask_c + i_wr_buf 锁存, 存进去的是
    //   "新组的旧数据" —— 实测第一个块末尾就错位 (first diff 619)。
    //   修法: 记住上一拍的写地址 wo_d (它就是刚写完的那一组), 用它算位图并存。
    reg [6:0] wo_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wo_d <= 7'd0;
        else        wo_d <= wo;
    end

    wire [63:0] nz_mask_d;
    generate
        for (gz = 0; gz < 64; gz = gz + 1) begin : g_nzd
            assign nz_mask_d[gz] = (qzz[wo_d + gz] != 16'sd0);
        end
    endgenerate

    reg [63:0] nz_r0, nz_r1;
    reg        q_done_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nz_r0    <= 64'd0;
            nz_r1    <= 64'd0;
            q_done_d <= 1'b0;
        end else begin
            q_done_d <= i_valid && (i_t == 3'd7);
            if (q_done_d) begin
                if (wo_d[6]) nz_r1 <= nz_mask_d;   // wo_d[6] = 刚写完的那一组
                else         nz_r0 <= nz_mask_d;
            end
        end
    end
    assign o_nz_mask = i_rd_buf ? nz_r1 : nz_r0;

endmodule
