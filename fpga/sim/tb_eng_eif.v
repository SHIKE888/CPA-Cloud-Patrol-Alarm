/*===========================================================================
 * tb_eng_eif.v —— jpeg_enc_if + 单引擎 最小复现
 *
 *   数据与 tb_jpeg_ddr4 里引擎 0 收到的完全一致:
 *     第 n 个 32b word = mkword(2n, 0)   ——— 即同一行的连续像素对
 *   但为了复现「四引擎下每引擎只吃 1/4 行」的时序, 这里可选两种送法:
 *     MODE 0 = 连续背靠背 (等同 tb_jpeg_merge4)
 *     MODE 1 = 突发: 每行只送 QW 个 64b word, 其余时间空 (等同真实 1/4 复用)
 *==========================================================================*/
`timescale 1ns / 1ps

module tb_eng_eif;

    localparam integer W4 = 128;    // 引擎宽 (px/行)
    localparam integer H  = 32;
    localparam integer RSTI = 8;
    localparam integer QW = W4/4;   // 每行 64b word 数 = 32
    localparam integer MODE = 1;    // 0=连续, 1=突发
    localparam integer SLVL = 288;   // enc_if 起送门限 (64b word)

    reg clk, rst_n;
    initial begin clk = 1'b0; rst_n = 1'b0; end
    always #5 clk = ~clk;

    function [7:0] pY;  input integer x, y; begin pY  = (x*3  + y*7 ) & 8'hFF; end endfunction
    function [7:0] pCb; input integer x, y; begin pCb = (x*5  + y*13) & 8'hFF; end endfunction
    function [7:0] pCr; input integer x, y; begin pCr = (x*11 + y*3 ) & 8'hFF; end endfunction
    function [31:0] mkword; input integer x0, y; begin
        mkword = { pCr(x0+1,y), pY(x0+1,y), pCb(x0,y), pY(x0,y) };
    end endfunction

    // 64b 源: 低半 = 早两像素
    reg         s_v;
    reg  [63:0] s_d;
    reg         s_sof;

    wire        e_v;
    wire [31:0] e_d;
    wire        e_rdy;
    wire [15:0] st_ovf, st_wl, st_sof;
    wire [9:0]  lvl;

    jpeg_enc_if #(.AW(10), .START_LEVEL(SLVL)) u_eif (
        .s_clk(clk), .s_rst_n(rst_n),
        .s_valid(s_v), .s_data(s_d), .s_sof(s_sof),
        .e_clk(clk), .e_rst_n(rst_n), .i_flush(1'b0),
        .e_valid(e_v), .e_data(e_d), .e_ready(e_rdy),
        .st_ovf(st_ovf), .st_word_lo(st_wl), .st_sof(st_sof), .o_level(lvl)
    );

    wire        m_v, m_l;
    wire [7:0]  m_d;
    wire [23:0] st_by;
    wire        st_busy, st_done, seg_done;
    wire [15:0] diag;
    wire [6:0]  qa, qb;
    wire [7:0]  qta, qtb;

    jpeg_qtable_ram u_qt (.I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0),
        .I_wr_addr(8'd0), .I_wr_data(8'd0),
        .I_rd_idx_a(qa), .O_rd_data_a(), .O_rd_data_a_asyn(qta),
        .I_rd_idx_b(qb), .O_rd_data_b(qtb));

    jpeg_encoder_top #(.W(W4), .H(H), .HDR_EN(1), .EOI_EN(0),
                       .RST_INIT(0), .RST_STEP(4), .LAST_RST_EN(1)) u_e (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_soft_rst(1'b0),
        .i_lossless(1'b0),
        .i_width(512), .i_height(H[11:0]), .i_rst_int(RSTI[15:0]),
        .o_qt_idx_a(qa), .i_qt_data_a(qta),
        .o_qt_idx_b(qb), .i_qt_data_b(qtb),
        .s_valid(e_v), .s_data(e_d), .s_ready(e_rdy),
        .m_valid(m_v), .m_data(m_d), .m_last(m_l), .m_ready(1'b1),
        .st_frame_bytes(st_by), .st_busy(st_busy), .st_done(st_done),
        .st_frame_cnt(), .o_seg_done(seg_done), .o_diag(diag));

    //------------------------------------------------------------------ 源
    integer n_wr = 0, nm = 0;
    initial begin : SRC
        integer y, k;
        s_v = 1'b0; s_d = 64'd0; s_sof = 1'b0;
        @(posedge rst_n);
        repeat (8) @(negedge clk);
        for (y = 0; y < H; y = y + 1) begin
            for (k = 0; k < QW; k = k + 1) begin
                @(negedge clk);
                s_v   = 1'b1;
                s_sof = (y == 0 && k == 0);
                s_d   = { mkword(4*k+2, y), mkword(4*k, y) };
                n_wr  = n_wr + 1;
            end
            @(negedge clk); s_v = 1'b0; s_sof = 1'b0;
            if (MODE == 1) repeat (3*QW*2) @(negedge clk);   // 空 3/4 行时间
        end
        @(negedge clk); s_v = 1'b0;
        $display("[SRC] done, %0d words (mode=%0d)", n_wr, MODE);
    end

    always @(posedge clk) if (m_v === 1'b1) nm = nm + 1;

    //------------------------------------------------------------------ 收尾
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        wait (n_wr == H*QW);
        repeat (40000) @(negedge clk);
        $display("--------------------------------------------------");
        $display("MODE=%0d SLVL=%0d  cyc=%0d  bytes=%0d", MODE, SLVL, cyc, nm);
        $display("st_by=%0d  busy=%b done=%b seg=%b", st_by, st_busy, st_done, seg_done);
        $display("eif: wl=%0d ovf=%0d rem=%0d", st_wl, st_ovf, lvl);
        $display("diag=%b", diag);
        $finish;
    end

    initial begin wait (cyc >= 200000); $display("TIMEOUT cyc=%0d bytes=%0d wl=%0d rem=%0d", cyc, nm, st_wl, lvl); $finish; end

endmodule
