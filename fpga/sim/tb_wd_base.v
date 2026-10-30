/*===========================================================================
 * tb_jpeg_full.v —— 4 引擎 + 字节桥 + CSI-2 变长组包器 全链路 (V52b)
 *
 *  为什么需要这个台架:
 *    tb_jpeg_ddr4 把 jpeg_seg_merge4 的 o_ready_down 硬接 1'b1 ——
 *    下游“永远可收”, 真实反压一次都没被验过。而板上 V51/V52 实测显示
 *    死锁就发生在 merge4 -> byte_bridge -> csi2_frame_tx_var 这一段:
 *      0xA5/A6 = 0x00/0x10 => encif_full=0x1, consume=0, mrg_segc=0
 *      引擎0 = 0x1442 => T_HDR, m_ready=0
 *    mrg_segc=0 说明 sel 未前进 => m_ready=0 只能来自 o_ready_down=0 => 桥满。
 *
 *  本台架把真实下游接上, 两个时钟也与板上一致:
 *    c_clk = 73.75MHz (编码器/合并器/桥写侧, 板上 S_clk_70m)
 *    b_clk = 125.0MHz (桥读侧/组包器,   板上 S_dsi_byte_clk)
 *
 *  判据:
 *    A) 不死锁: merge4 能吐完一帧 (m_segc 到达 4*H, 桥写满 6007 字节)
 *    B) 逐字节正确: 组包器吐出的 payload == ddr4.jpg 基准
 *    C) 像素通路自检全 0 (同 tb_jpeg_ddr4)
 *==========================================================================*/
`timescale 1ns / 1ps

module tb_wd_base;

    localparam integer W1   = 512;
    localparam integer W4   = 128;
    localparam integer H    = 32;
    localparam integer RSTI = 8;
    localparam integer QW   = W1/4/4;
    localparam integer NSEG = 4*H;
    localparam integer BYP_MRG = 0;
    // ★ 与板上一致: 8 行预取 (板上 8x240=1920)
    localparam integer SLVL = 16*QW;

    reg r_clk, c_clk, b_clk, rst_n, brst_n;
    initial begin r_clk = 1'b0; c_clk = 1'b0; b_clk = 1'b0;
                  rst_n = 1'b0; brst_n = 1'b0; end
    always #4.752 r_clk = ~r_clk;    // 9.504 ns -> 105.2 MHz (dbuf 读侧)
    always #7.118 c_clk = ~c_clk;    // 14.236 ns -> 70.238 MHz (板上 S_clk_70m, V53a 实测)

    // ★ 看门狗派生的控制 (复刻 system_top 的 i_flush / i_soft_rst / i_start)
    wire        wd_flush, wd_soft, m_start;
    always #4.000 b_clk = ~b_clk;    // 8.00 ns  -> 125.0 MHz (板上 S_dsi_byte_clk)

    //------------------------------------------------------------------ 图案
    function [7:0] pY;  input integer x, y; begin pY  = (x*3  + y*7 ) & 8'hFF; end endfunction
    function [7:0] pCb; input integer x, y; begin pCb = (x*5  + y*13) & 8'hFF; end endfunction
    function [7:0] pCr; input integer x, y; begin pCr = (x*11 + y*3 ) & 8'hFF; end endfunction

    // 与 tb_jpeg_merge4 完全相同的像素打包 -> 可直接与 merged4.jpg 逐字节比对
    function [31:0] mkword; input integer x0, y; begin
        mkword = { pCr(x0,y), pY(x0+1,y), pCb(x0,y), pY(x0,y) };
    end endfunction

    //-------------------------------------------------------- 源 (dbuf 读侧)
    reg         r_v;
    reg  [31:0] r_d;
    reg         r_sof, r_last;
    wire        r_rdy;

    wire        c_v, c_sof, c_last;
    wire [63:0] c_d;
    // ★ 与 RTL 一致: 源只受 enc_if 的 FIFO 满反压, 不受帧门控
    reg         c_rdy_en;
    wire [3:0]  x_full;
    wire        c_rdy = c_rdy_en & ~(|x_full);
    initial c_rdy_en = 1'b0;

    yuv32_to_quad u_conv (
        .r_clk(r_clk), .r_rst_n(rst_n),
        .r_valid(r_v), .r_data(r_d), .r_sof(r_sof), .r_last(r_last),
        .r_ready(r_rdy),
        .c_clk(c_clk), .c_rst_n(rst_n),
        .c_valid(c_v), .c_data(c_d), .c_sof(c_sof), .c_last(c_last),
        .c_ready(c_rdy)
    );

    //------------------------------------------------------ 行内 1/4 分组
    reg  [9:0] gcnt;
    wire [3:0] gvld = { (gcnt >= 3*QW),
                        (gcnt >= 2*QW) && (gcnt < 3*QW),
                        (gcnt >= 1*QW) && (gcnt < 2*QW),
                        (gcnt <  1*QW) };

    // 必须用 c_v & c_rdy 计数: gate=0 时 c_valid 会常高, 只用 c_v 会把分组冲飞
    always @(posedge c_clk or negedge rst_n) begin
        if (!rst_n)            gcnt <= 10'd0;
        else if (c_v && c_rdy) gcnt <= c_last ? 10'd0 : (gcnt + 10'd1);
    end

    //------------------------------------------------------ 4x jpeg_enc_if
    wire [3:0]  x_ev, x_erd;
    wire [31:0] x_ed [0:3];
    wire [15:0] x_wl [0:3];
    wire [15:0] x_ovf[0:3];

    genvar gi;
    generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_if
        jpeg_enc_if #(.AW(12), .START_LEVEL(SLVL)) u_enc_if (
            .s_clk      (c_clk          ),
            .s_rst_n    (rst_n          ),
            // ★ 必须带 c_rdy: yuv32_to_quad 在 c_ready=0 时会保持 c_valid 不变,
            //   若只用 c_v, 同一个字会被重复写进 FIFO (本次仿真已复现)
            .s_valid    (c_v & c_rdy & gvld[gi]),
            .s_data     (c_d            ),
            .s_sof      (c_sof          ),
            .e_clk      (c_clk          ),
            .e_rst_n    (rst_n          ),
            .i_flush    (wd_flush        ),
            .e_valid    (x_ev[gi]       ),
            .e_data     (x_ed[gi]       ),
            .e_ready    (x_erd[gi]      ),
            .st_ovf     (x_ovf[gi]      ),
            .st_word_lo (x_wl[gi]       ),
            .st_sof     (               ),
            .o_level    (               ),
            .o_full     (x_full[gi]     )
        );
    end
    endgenerate

    //------------------------------------------------------ 4 引擎 + 量化表
    wire [3:0]  e_rdy, e_mv, e_ml, e_seg, e_bs, e_bd;
    wire [3:0]  e_mrdy = BYP_MRG ? 4'b1111 : e_rdy;
    wire [7:0]  e_md [0:3];
    wire [23:0] e_by [0:3];
    wire [31:0] e_bc [0:3];
    wire [15:0] e_dg [0:3];
    wire [6:0]  e_qa [0:3], e_qb [0:3];
    wire [7:0]  e_qta[0:3], e_qtb[0:3];

    genvar gq;
    generate
    for (gq = 0; gq < 4; gq = gq + 1) begin : g_qt
        jpeg_qtable_ram u_qt (.I_clk(c_clk), .I_rst_n(rst_n), .I_wr_en(1'b0),
            .I_wr_addr(8'd0), .I_wr_data(8'd0),
            .I_rd_idx_a(e_qa[gq]), .O_rd_data_a(), .O_rd_data_a_asyn(e_qta[gq]),
            .I_rd_idx_b(e_qb[gq]), .O_rd_data_b(e_qtb[gq]));
    end
    endgenerate

    genvar ge;
    generate
    for (ge = 0; ge < 4; ge = ge + 1) begin : g_enc
        jpeg_encoder_top #(.W(W4), .H(H),
                           .HDR_EN(ge == 0 ? 1 : 0),
                           .EOI_EN(ge == 3 ? 1 : 0),
                           .RST_INIT(ge),
                           .RST_STEP(4),
                           .LAST_RST_EN(ge == 3 ? 0 : 1)) u_e (
            .clk(c_clk), .rst_n(rst_n), .i_en(1'b1), .i_soft_rst(wd_soft),
            .i_lossless(1'b0),
            .i_width(W1[11:0]), .i_height(H[11:0]), .i_rst_int(RSTI[15:0]),
            .o_qt_idx_a(e_qa[ge]), .i_qt_data_a(e_qta[ge]),
            .o_qt_idx_b(e_qb[ge]), .i_qt_data_b(e_qtb[ge]),
            .s_valid(x_ev[ge]), .s_data(x_ed[ge]), .s_ready(x_erd[ge]),
            .m_valid(e_mv[ge]), .m_data(e_md[ge]), .m_last(e_ml[ge]),
            .m_ready(e_mrdy[ge]),
            .st_frame_bytes(e_by[ge]), .st_busy(e_bs[ge]), .st_done(e_bd[ge]),
            .st_frame_cnt(e_bc[ge]), .o_seg_done(e_seg[ge]), .o_diag(e_dg[ge]));
    end
    endgenerate

    //------------------------------------------------------ 合并器 (4:1)
    wire        m_v, m_l;
    wire [7:0]  m_d;
    wire [9:0]  m_segc;
    // m_start 由看门狗块组合产生 (见下方 WD 段), 这里不再声明 reg

    wire [31:0] e_d_pack = { e_md[3], e_md[2], e_md[1], e_md[0] };

    // ★ 字节桥相关信号必须先声明 (merge4 的 o_ready_down 要用 bw_rdy)
    wire        bw_rdy, br_v, br_l, br_r;
    wire [7:0]  br_d;
    wire [15:0] bw_bp;
    wire [11:0] br_lvl;

    jpeg_seg_merge4 u_mrg (
        .clk(c_clk), .rst_n(rst_n), .i_start(m_start),
        .i_valid(e_mv), .i_data(e_d_pack), .i_last(e_ml),
        .o_ready(e_rdy), .i_seg_done(e_seg),
        .o_valid(m_v), .o_data(m_d), .o_last(m_l),
        .o_ready_down(bw_rdy),          // ★ 真实反压: 字节桥 w_ready
        .o_seg_cnt(m_segc));

    //-------------------------------------------------- 字节桥 (512B 异步 FIFO)
    jpeg_byte_bridge #(.AW(12)) u_br (
        .w_clk  (c_clk), .w_rst_n(rst_n),
        .w_valid(m_v),   .w_data (m_d),  .w_last(m_l), .w_ready(bw_rdy),
        .r_clk  (b_clk), .r_rst_n(brst_n),
        .r_valid(br_v),  .r_data (br_d), .r_last(br_l), .r_ready(br_r),
        .st_bp  (bw_bp),  .o_level(br_lvl));

    //-------------------------------------------------- CSI-2 变长组包器
    wire        tx_v, tx_r;
    wire [31:0] tx_hs_d;
    wire        tx_hs_en, tx_hs_l;
    wire [31:0] tx_pkt;
    wire [31:0] tx_byc, tx_frm;

    csi2_frame_tx_var #(.PKT_BYTES(1024), .GAP_FRAME(200), .VC(2'b00)) u_tx (
        .clk(b_clk), .rst_n(brst_n), .enable(1'b1),
        .i_dt(6'h1E),
        .s_tvalid(br_v), .s_tdata(br_d), .s_tlast(br_l), .s_tready(tx_r),
        .hs_en(tx_hs_en), .hs_data(tx_hs_d), .hs_last(tx_hs_l),
        .frame_cnt(tx_frm), .packet_cnt(tx_pkt), .byte_cnt(tx_byc));

    // 与 system_top 一致: DATA 状态下直接放行 (JPAD 关闭)
    assign br_r = tx_r;
    assign tx_v = br_v;

    //------------------------------------------------------ 自检
    integer err_px = 0, err_last = 0, err_sof = 0, err_grp = 0;
    integer n_sof = 0, n_last = 0, n_word = 0;
    integer exp_px, exp_y;
    integer n_in [0:3];
    integer n_rd32[0:3];

    initial begin exp_px = 0; exp_y = 0; end

    always @(posedge c_clk) begin
        if (rst_n && c_v && c_rdy) begin
            n_word = n_word + 1;
            if (c_sof)  n_sof  = n_sof + 1;
            if (c_last) n_last = n_last + 1;
            if (c_d[31:0] !== mkword(exp_px, exp_y)) begin
                if (err_px < 6)
                    $display("[ERR-PX] w#%0d y=%0d x=%0d lo=%h exp=%h",
                             n_word, exp_y, exp_px, c_d[31:0], mkword(exp_px, exp_y));
                err_px = err_px + 1;
            end
            if (c_d[63:32] !== mkword(exp_px+2, exp_y)) begin
                if (err_px < 6)
                    $display("[ERR-PX] w#%0d y=%0d x=%0d hi=%h exp=%h",
                             n_word, exp_y, exp_px+2, c_d[63:32], mkword(exp_px+2, exp_y));
                err_px = err_px + 1;
            end
            if (c_last !== ((exp_px == W1-4) ? 1'b1 : 1'b0)) begin
                if (err_last < 6)
                    $display("[ERR-LAST] w#%0d y=%0d x=%0d last=%b", n_word, exp_y, exp_px, c_last);
                err_last = err_last + 1;
            end
            if (c_sof !== ((exp_px == 0 && exp_y == 0) ? 1'b1 : 1'b0)) begin
                if (err_sof < 6)
                    $display("[ERR-SOF] w#%0d y=%0d x=%0d sof=%b", n_word, exp_y, exp_px, c_sof);
                err_sof = err_sof + 1;
            end
            if (c_last) begin exp_px = 0; exp_y = (exp_y + 1) % H; end
            else        begin exp_px = exp_px + 4; end
        end
    end

    genvar gk;
    generate
    for (gk = 0; gk < 4; gk = gk + 1) begin : g_chk
        integer cnt, line, bad, bad32;
        integer wl;                      // 本引擎已收 32b word 序号
        integer cw;                      // 本引擎累计被写入的 64b word 数
        initial begin cnt = 0; line = 0; bad = 0; bad32 = 0; wl = 0; cw = 0;
                      n_in[gk] = 0; n_rd32[gk] = 0; end
        always @(posedge c_clk) begin
            if (rst_n && c_v && c_rdy && gvld[gk]) begin cnt = cnt + 1; cw = cw + 1; end
            if (rst_n && c_v && c_rdy && c_last) begin
                if (cnt != QW) begin
                    if (bad < 4)
                        $display("[ERR-GRP] eng%0d line%0d got %0d word, exp %0d",
                                 gk, line, cnt, QW);
                    bad = bad + 1; err_grp = err_grp + 1;
                end
                cnt = 0; line = line + 1;
            end
            if (rst_n && x_ev[gk]) n_in[gk] = n_in[gk] + 1;
            // ★ 引擎实际收到的 32b 序列逐字比对
            //   期望: 第 n 个 word = 行 (n/(W4/2)), 行内第 (n%(W4/2)) 个 -> x0 = gk*W4 + 2k
            if (rst_n && x_ev[gk] && x_erd[gk]) begin
                if (x_ed[gk] !== mkword(gk*W4 + 2*(wl % (W4/2)),
                                        (wl / (W4/2)) % H)) begin
                    if (bad32 < 4)
                        $display("[ERR-E32] eng%0d word#%0d got=%h exp=%h",
                                 gk, wl, x_ed[gk],
                                 mkword(gk*W4 + 2*(wl % (W4/2)), (wl / (W4/2)) % H));
                    bad32 = bad32 + 1;
                end
                wl = wl + 1;
                n_rd32[gk] = n_rd32[gk] + 1;
            end
        end
    end
    endgenerate

    //------------------------------------------------------ 源激励
    initial begin : SRC
        integer y, k;
        r_v = 1'b0; r_d = 32'd0; r_sof = 1'b0; r_last = 1'b0;
        @(posedge rst_n);
        repeat (8) @(negedge r_clk);
        for (y = 0; y < H; y = y + 1) begin
            for (k = 0; k < W1/2; k = k + 1) begin
                @(negedge r_clk);
                r_v    = 1'b1;
                r_sof  = (y == 0 && k == 0);
                r_last = (k == W1/2 - 1);
                r_d    = mkword(2*k, y);
                @(posedge r_clk);
                while (!r_rdy) @(posedge r_clk);
            end
        end
        @(negedge r_clk); r_v = 1'b0; r_sof = 1'b0; r_last = 1'b0;
        $display("[TB] source done at %0t", $time);
    end

    //------------------------------------------------------ 输出到文件
    // 桥写侧被接走的字节 (应 == 6007)
    integer fdm, nm;
    initial begin fdm = $fopen("full.jpg", "wb"); nm = 0; end
    always @(posedge c_clk) if (m_v === 1'b1 && bw_rdy === 1'b1) begin
        $fwrite(fdm, "%c", m_d); nm = nm + 1; end

    // 组包器吐出的字节 (含 CSI-2 包头/CRC, 只看是否在前进)
    integer txb;
    initial txb = 0;
    always @(posedge b_clk) if (tx_hs_en === 1'b1) txb = txb + 1;

    //------------------------------------------------------ 复位 / 门控 / 启动
    initial begin
        repeat (10) @(negedge c_clk);
        rst_n = 1'b1;
        $display("[TB] reset released at %0t", $time);
        repeat (34) @(negedge c_clk);
        brst_n = 1'b1;
        c_rdy_en = 1'b1;
        $display("[TB] gate open at %0t", $time);
    end

    // ★ 4:1 字节 mux 的吞吐测量：每个引擎"有字节要吐"的拍里, 有多少拍被允许吐
    //   这是判断"串行 mux 是否把 4 引擎并行化掉"的关键指标。
    integer mv_cyc [0:3];
    integer rd_cyc [0:3];
    integer mv_stall [0:3];
    integer mux_hold [0:3];
    integer last_sel = -1;
    integer hold_now = 0;
    integer gi2;
    initial begin
        for (gi2 = 0; gi2 < 4; gi2 = gi2 + 1) begin
            mv_cyc[gi2] = 0; rd_cyc[gi2] = 0; mv_stall[gi2] = 0; mux_hold[gi2] = 0;
        end
    end
    always @(posedge c_clk) begin
        if (rst_n) begin
            for (gi2 = 0; gi2 < 4; gi2 = gi2 + 1) begin
                if (e_mv[gi2]) begin
                    mv_cyc[gi2] = mv_cyc[gi2] + 1;
                    if (e_mrdy[gi2]) rd_cyc[gi2] = rd_cyc[gi2] + 1;
                    else             mv_stall[gi2] = mv_stall[gi2] + 1;
                end
            end
            if (u_mrg.sel != last_sel) begin
                if (last_sel >= 0) mux_hold[last_sel] = mux_hold[last_sel] + hold_now;
                last_sel = u_mrg.sel;
                hold_now = 1;
            end else hold_now = hold_now + 1;
        end
    end
    integer cyc = 0;
    always @(posedge c_clk) cyc = cyc + 1;

    reg mux_rpt = 1'b0;
    always @(posedge c_clk) begin
        // 在一帧基本吐完之后打一次报告
        if (rst_n && !mux_rpt && (cyc >= 50000)) begin
            mux_rpt = 1'b1;
            $display("MUX: eng  valid_cyc  ready_cyc  stalled  blocked%%  mux_hold_cyc");
            for (gi2 = 0; gi2 < 4; gi2 = gi2 + 1) begin
                $display("MUX: %0d    %8d   %8d  %8d   %5d%%     %8d",
                         gi2, mv_cyc[gi2], rd_cyc[gi2], mv_stall[gi2],
                         (mv_cyc[gi2] == 0) ? 0 : (100*mv_stall[gi2]/mv_cyc[gi2]),
                         mux_hold[gi2]);
            end
        end
    end


    //==========================================================================
    //  ★ 复刻 system_top 的"卡死看门狗"—— 这才是板上独有的东西
    //    系统侧: ENC_WD_MAX = 8_000_000 @70.238MHz = 114ms
    //    这里 WD_USE_PROG=0 时改成"引擎在忙每 WD_MAX 拍无条件触发", 做压力测试;
    //    WD_USE_PROG=1 且 WD_MAX=8_000_000 时与板上完全一致 (但仿真跑不到)。
    //==========================================================================
    parameter integer WD_MAX      = 6000;
    parameter integer WD_USE_PROG = 0;
    parameter integer WD_EN_FLUSH = 1;   // 0 = 不断言 i_flush
    parameter integer WD_EN_SOFT  = 1;   // 0 = 不断言 i_soft_rst
    parameter integer MS_ONE_SHOT = 0;   // 1 = m_start 只在上电时打一拍 (旧台架行为)
    parameter integer MS_MODE = 0;       // 0 = 板上原样 (busy0 上升沿 | rst_rel)
                                          // 1 = 只 rst_rel (候选修法)
                                          // 2 = busy0 上升沿 only (拿掉 rst_rel)

    reg [23:0] wd_cnt    = 24'd0;
    reg [5:0]  wd_wdc    = 6'd0;
    reg [15:0] wd_stall  = 16'd0;
    reg [15:0] wd_prog_d = 16'd0;
    reg        wd_soft_d = 1'b0;
    reg        busy0_d   = 1'b0;
    integer    wd_stall_d = -1;

    wire [15:0] wd_prog = x_wl[0] + x_wl[1] + x_wl[2] + x_wl[3];

    assign wd_flush = (wd_wdc != 6'd0) && (WD_EN_FLUSH != 0);
    assign wd_soft  = (wd_wdc > 6'd16) && (WD_EN_SOFT  != 0);
    wire   wd_rst_rel = wd_soft_d & ~wd_soft;
    wire   ms_busy    = e_bs[0] & ~busy0_d;
    wire   ms_sel     = (MS_MODE == 1) ? wd_rst_rel :
                        (MS_MODE == 2) ? ms_busy    : (ms_busy | wd_rst_rel);
    // 板上真实接法: m_start = 引擎0 busy 上升沿 | 软复位释放拍
    assign m_start    = (MS_ONE_SHOT != 0) ? (cyc == 14) : ms_sel;

    always @(posedge c_clk or negedge rst_n) begin
        if (!rst_n) begin
            wd_cnt <= 24'd0; wd_wdc <= 6'd0; wd_stall <= 16'd0;
            wd_prog_d <= 16'd0; wd_soft_d <= 1'b0; busy0_d <= 1'b0;
        end else begin
            wd_soft_d <= wd_soft;
            busy0_d   <= e_bs[0];
            if (wd_wdc != 6'd0) begin
                wd_wdc <= wd_wdc - 6'd1;
                wd_cnt <= 24'd0;
            end else if (WD_USE_PROG && (wd_prog != wd_prog_d)) begin
                wd_prog_d <= wd_prog;
                wd_cnt    <= 24'd0;
            end else if (!(|e_bs)) begin
                wd_cnt <= 24'd0;
            end else if (wd_cnt >= WD_MAX) begin
                wd_wdc   <= 6'd31;
                wd_cnt   <= 24'd0;
                wd_stall <= wd_stall + 16'd1;
            end else begin
                wd_cnt <= wd_cnt + 24'd1;
            end
        end
    end

    always @(posedge c_clk) begin
        if (rst_n && (wd_stall != wd_stall_d)) begin
            wd_stall_d = wd_stall;
            $display("[WD] cyc=%0d stall=%0d e0=%h e3=%h segc=%0d full=%b prog=%0d brlvl=%0d",
                     cyc, wd_stall, e_dg[0], e_dg[3], m_segc, x_full, wd_prog, br_lvl);
        end
    end

    // ★ 逐级探针: 看 flush 之后 enc_if 为什么不再转发
    always @(posedge c_clk) begin
        if (rst_n && (cyc % 4000 == 0) && (cyc >= 4000) && (cyc <= 60000)) begin
            $display("[P] cyc=%0d | if0: rdgo=%b rcnt=%0d full=%b empty=%b | rd: wv=%b dv=%b wrdy=%b | srdy0=%b | wl0=%0d wl3=%0d",
                     cyc,
                     g_if[0].u_enc_if.rd_go, g_if[0].u_enc_if.f_rcnt, g_if[0].u_enc_if.f_full, g_if[0].u_enc_if.f_empty,
                     g_if[0].u_enc_if.w_v, g_if[0].u_enc_if.d_v, x_erd[0], e_rdy[0],
                     x_wl[0], x_wl[3]);
        end
    end

    // ★ 逐拍追踪: 引擎0 bitpack 内部 (只在 100000~100050 拍打)
    always @(posedge c_clk) begin
        if (rst_n && cyc >= 100000 && cyc < 100040) begin
            $display("TR n=%0d np=%0d put=%b iv=%b len=%0d hv=%b ov=%b ordy=%b ogo=%b hst=%0d hfin=%b",
                g_enc[0].u_e.u_bitpack.n, g_enc[0].u_e.u_bitpack.n_p,
                g_enc[0].u_e.u_bitpack.do_put,
                g_enc[0].u_e.u_bitpack.i_valid,
                g_enc[0].u_e.u_bitpack.i_len,
                g_enc[0].u_e.u_bitpack.has_byte,
                g_enc[0].u_e.u_bitpack.o_valid,
                g_enc[0].u_e.u_bitpack.o_ready,
                g_enc[0].u_e.u_bitpack.out_go,
                g_enc[0].u_e.u_huff.state,
                g_enc[0].u_e.huff_done);
        end
    end
    // ★ 计数: huff_done 上升沿 / seg_done / pend 变化, 判断熵编码是否真在完成
    integer n_hd0 = 0, n_seg0 = 0, n_pendchg = 0;
    reg hd0_d = 1'b0, pg_d = 1'b0, seg0_d = 1'b0;
    always @(posedge c_clk) begin
        hd0_d <= e_dg[0][14];
        seg0_d <= e_seg[0];
        pg_d  <= e_dg[0][5];
        if (rst_n && e_dg[0][14] && !hd0_d) n_hd0 = n_hd0 + 1;
        if (rst_n && e_seg[0] && !seg0_d)   n_seg0 = n_seg0 + 1;
        if (rst_n && pg_d !== e_dg[0][5])   n_pendchg = n_pendchg + 1;
    end

    // ★ 引擎0 内部探针: 看 bitpack 的 n / o_valid / o_ready 到底怎么跑飞
    integer pr = 0;
    always @(posedge c_clk) begin
        if (rst_n && (cyc % 20000 == 0) && (pr < 12)) begin
            pr = pr + 1;
            $display("PROBE cyc=%0d e0: ts=%0d pend=%0d hrun=%b bp_ok=%b mrdy=%b | bp: n=%0d o_v=%b o_r=%b | mrg sel=%0d segc=%0d",
                     cyc, e_dg[0][3:0], e_dg[0][5:4], e_dg[0][8], e_dg[0][10], e_dg[0][11],
                     g_enc[0].u_e.u_bitpack.n,
                     g_enc[0].u_e.m_valid, g_enc[0].u_e.m_ready,
                     u_mrg.sel, u_mrg.o_seg_cnt);
        end
    end

    // ★ 诊断: 引擎0 在 row3 (enc_mcu>=24) 的 DC 预测器状态 (S_DC 拍)
    always @(posedge c_clk) begin
        if (rst_n && g_enc[0].u_e.enc_mcu >= 24 && g_enc[0].u_e.u_huff.state == 3'd1) begin
            $display("E0DC mcu=%0d comp=%0d pred=%0d/%0d/%0d rd=%0d rstpred=%b",
                     g_enc[0].u_e.enc_mcu, g_enc[0].u_e.u_huff.i_comp,
                     g_enc[0].u_e.u_huff.pred_y, g_enc[0].u_e.u_huff.pred_cb, g_enc[0].u_e.u_huff.pred_cr,
                     g_enc[0].u_e.u_huff.i_rd_data, g_enc[0].u_e.u_huff.i_rst_pred);
        end
    end

    // 输出停滞检测: nm 与 txb 同时 30000 拍不变 = 链路已停 (正常吐完 或 死锁)
    integer nm_d = 0, txb_d = 0, stall = 0;
    always @(posedge c_clk) begin
        if ((nm != nm_d) || (txb != txb_d)) begin
            nm_d = nm; txb_d = txb; stall = 0;
        end else stall = stall + 1;
    end

    initial begin
        // 四个引擎都把本帧 1024 个 64b word 吃完 -> 再等输出完全吐干净
        wait ((x_wl[0] == W1*H/4/4) && (x_wl[1] == W1*H/4/4) &&
              (x_wl[2] == W1*H/4/4) && (x_wl[3] == W1*H/4/4));
        wait (stall > 30000);
        $fclose(fdm);
        $display("--------------------------------------------------");
        $display("WORDS   : %0d  (exp %0d)", n_word, W1*H/4);
        $display("SOF     : %0d  (exp 1)", n_sof);
        $display("LAST    : %0d  (exp %0d)", n_last, H);
        $display("ERR  px=%0d last=%0d sof=%0d grp=%0d", err_px, err_last, err_sof, err_grp);
        $display("MERGED  : %0d bytes  segcnt=%0d  cyc=%0d", nm, m_segc, cyc);
        $display("TXBYTES : %0d  (含 CSI-2 包头/CRC)  pkt=%0d  frm=%0d", txb, tx_pkt, tx_frm);
        $display("BRIDGE  : level=%0d  wbp=%0d  (level=511 即贴满)", br_lvl, bw_bp);
        $display("ENG in  : %0d/%0d/%0d/%0d   rd32=%0d/%0d/%0d/%0d",
                 n_in[0], n_in[1], n_in[2], n_in[3],
                 n_rd32[0], n_rd32[1], n_rd32[2], n_rd32[3]);
        $display("ENG by  : %0d/%0d/%0d/%0d  wl=%0d/%0d/%0d/%0d  ovf=%b",
                 e_by[0], e_by[1], e_by[2], e_by[3],
                 x_wl[0], x_wl[1], x_wl[2], x_wl[3],
                 (|x_ovf[0]) | (|x_ovf[1]) | (|x_ovf[2]) | (|x_ovf[3]));
        if (err_px == 0 && err_last == 0 && err_sof == 0 && err_grp == 0)
            $display("PIXEL PATH  OK");
        else
            $display("PIXEL PATH  FAIL");
        $finish;
    end

    initial begin
        wait (cyc >= 250000);
        $display("INNER0 pend=%0d pnx=%0d rst_busy=%b rst_req=%b hstart=%b hrun=%b enc_mcu=%0d my=%0d mx=%0d blk=%0d rst_cnt=%0d",
                 g_enc[0].u_e.pend, g_enc[0].u_e.pend_nx, g_enc[0].u_e.rst_busy, g_enc[0].u_e.rst_req,
                 g_enc[0].u_e.huff_start, g_enc[0].u_e.huff_run, g_enc[0].u_e.enc_mcu,
                 g_enc[0].u_e.my, g_enc[0].u_e.mx_reg, g_enc[0].u_e.blk, g_enc[0].u_e.rst_cnt);
        $display("CNT0 huff_done=%0d seg_done=%0d pend_chg=%0d", n_hd0, n_seg0, n_pendchg);
        $display("TIMEOUT cyc=%0d merged=%0d segcnt=%0d words=%0d txb=%0d",
                 cyc, nm, m_segc, n_word, txb);
        $display("BRIDGE  : level=%0d  wbp=%0d", br_lvl, bw_bp);
        $display("ENG in  : %0d/%0d/%0d/%0d   rd32=%0d/%0d/%0d/%0d",
                 n_in[0], n_in[1], n_in[2], n_in[3],
                 n_rd32[0], n_rd32[1], n_rd32[2], n_rd32[3]);
        $display("ENG by  : %0d/%0d/%0d/%0d  wl=%0d/%0d/%0d/%0d  ovf=%b",
                 e_by[0], e_by[1], e_by[2], e_by[3],
                 x_wl[0], x_wl[1], x_wl[2], x_wl[3],
                 (|x_ovf[0]) | (|x_ovf[1]) | (|x_ovf[2]) | (|x_ovf[3]));
        $display("ENG wr  : %0d/%0d/%0d/%0d  (每引擎应 %0d)",
                 g_chk[0].cw, g_chk[1].cw, g_chk[2].cw, g_chk[3].cw, W1*H/4/4);
        $display("ENG busy=%b done=%b srdy=%b mrdy=%b mv=%b seg=%b",
                 e_bs, e_bd, x_erd, e_rdy, e_mv, e_seg);
        $display("FIFO rem : %0d/%0d/%0d/%0d   (enc_if 里剩余 64b word)",
                 g_if[0].u_enc_if.f_rcnt, g_if[1].u_enc_if.f_rcnt,
                 g_if[2].u_enc_if.f_rcnt, g_if[3].u_enc_if.f_rcnt);
        $display("ENG srdy : %b  mv=%b  by=%0d/%0d",
                 x_erd, e_mv, e_by[0], e_by[2]);
        $display("DIAG tstate  : %0d/%0d/%0d/%0d  (0=IDLE 2=HDR 3=WGRP 7=NEXT 8=FIN 9=EOI)",
                 e_dg[0][3:0], e_dg[1][3:0], e_dg[2][3:0], e_dg[3][3:0]);
        $display("DIAG pend    : %0d/%0d/%0d/%0d",
                 e_dg[0][5:4], e_dg[1][5:4], e_dg[2][5:4], e_dg[3][5:4]);
        $display("DIAG lb_aval : %b/%b/%b/%b   bp_ok=%b/%b/%b/%b",
                 e_dg[0][6], e_dg[1][6], e_dg[2][6], e_dg[3][6],
                 e_dg[0][10], e_dg[1][10], e_dg[2][10], e_dg[3][10]);
        $display("DIAG m_ready : %b/%b/%b/%b   huff_run=%b/%b/%b/%b",
                 e_dg[0][11], e_dg[1][11], e_dg[2][11], e_dg[3][11],
                 e_dg[0][8], e_dg[1][8], e_dg[2][8], e_dg[3][8]);
        $fclose(fdm);
        $finish;
    end

endmodule
