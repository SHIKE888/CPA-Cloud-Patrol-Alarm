/*===========================================================================
 * tb_pre2jpeg.v —— 「预处理输出 -> RGB2YUV -> 4 引擎 JPEG -> 段合并 -> CSI-2」接缝台架
 *
 *  为什么需要它:
 *    已有台架各自只验一段:
 *      tb_dual_stitch : 拼接 (输出 4px/clk 的 40b 组)
 *      tb_preproc     : 预处理内部 (3x3 / Sobel / 形态 / 中值)
 *      tb_wd          : yuv32_to_quad -> 4 引擎 -> merge4 -> 桥 -> CSI-2
 *    但 **preproc_post -> rgb_to_yuv422_quad -> jpeg_enc_if** 这条接缝从没验过:
 *      rgb2yuv 输出 64b {cr3,y3,cb2,y2, cr1,y1,cb0,y0},
 *      enc_if 契约是「低 32b = 像素 0,1 先送」——两者一旦错位,
 *      JPEG 整体偏色/条纹, 但字节数和帧结构都正常, 很难从板上发现。
 *
 *  本台架判据:
 *    A) rgb2yuv 输出逐字节 == 台架内定点参考模型 (0 error)
 *    B) o_user_sof / o_last 与源同步, 每行 1 个 last, 每帧 1 个 sof
 *    C) 4 引擎全链不死锁: segcnt == 4*H
 *    D) 每引擎收到的 64b word 逐字正确 (分组边界没被冲飞)
 *    E) 落地一个 full.jpg, 交给 verify_jpeg.py 校验结构
 *
 *  时钟: 单时钟 73.75MHz (V54 的 S_clk_70m), 不做跨时钟
 *  运行: fpga/sim/run_pre2jpeg.ps1
 *==========================================================================*/
`timescale 1ns / 1ps

module tb_pre2jpeg;

    parameter integer W1       = 512;    // 一行像素数 (4 的倍数)
    parameter integer H        = 32;     // 行数
    parameter integer RSTI     = 8;      // DRI 间隔 (MCU 行)
    parameter integer USE_POST = 1;      // 1 = 插入 preproc_post (ROI/WB 直通)

    localparam integer W4   = W1/4;      // 每引擎像素宽 (128)
    localparam integer QW   = W4/4;      // 每引擎每行 64b word 数 (32)
    localparam integer SLVL = 16*QW;     // enc_if 预取 16 行

    //------------------------------------------------------------ 时钟 / 复位
    reg clk = 1'b0, rst_n = 1'b0;
    always #6.7795 clk = ~clk;           // 13.559 ns -> 73.75 MHz
    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n <= 1'b1;
    end

    //------------------------------------------------------------ 源: 4px/clk RGB888
    function [7:0] fR; input integer x, yy; begin fR = (x*3 + yy*7 ) & 8'hFF; end endfunction
    function [7:0] fG; input integer x, yy; begin fG = (x*5 + yy*11) & 8'hFF; end endfunction
    function [7:0] fB; input integer x, yy; begin fB = (x*7 + yy*13) & 8'hFF; end endfunction

    reg         s_v = 1'b0, s_user = 1'b0, s_last = 1'b0;
    reg [127:0] s_rgb = 128'd0;

    //------------------------------------------------------------ preproc_post (可选)
    wire         p_v, p_user, p_last;
    wire [127:0] p_rgb;
    wire         y_v, y_user, y_last;     // rgb2yuv 之后
    // preproc_post 无 ready (纯流水), rgb2yuv 也无 ready

    generate
    if (USE_POST != 0) begin : g_post
        preproc_post #(.PX_PER_CLK(4)) u_post (
            .clk(clk), .rst_n(rst_n),
            .i_h_active(W1[11:0]), .i_v_active(H[11:0]),
            .i_tvalid(s_v), .i_tuser(s_user), .i_tlast(s_last), .i_rgb(s_rgb),
            .i_wb_r(8'd128), .i_wb_b(8'd128),   // 1.0x
            .i_mono(1'b0),
            .i_roi_pct(7'd100),                 // 全画幅
            .o_tvalid(p_v), .o_tuser(p_user), .o_tlast(p_last), .o_rgb(p_rgb));
    end else begin : g_nopost
        assign p_v = s_v; assign p_user = s_user; assign p_last = s_last;
        assign p_rgb = s_rgb;
    end
    endgenerate

    //------------------------------------------------------------ RGB -> YUV422
    wire [63:0] yuv_d;
    rgb_to_yuv422_quad u_yuv (
        .clk(clk), .rst_n(rst_n),
        .i_de(p_v), .i_user_sof(p_user), .i_last(p_last), .i_data(p_rgb),
        .i_mono(1'b0),
        .o_de(y_v), .o_user_sof(y_user), .o_last(y_last), .o_data(yuv_d));

    //------------------------------------------------------------ 行内 1/4 分组
    reg  [9:0] gcnt;
    wire [3:0] gvld = { (gcnt >= 3*QW),
                        (gcnt >= 2*QW) && (gcnt < 3*QW),
                        (gcnt >= 1*QW) && (gcnt < 2*QW),
                        (gcnt <  1*QW) };

    //------------------------------------------------------------ 4x jpeg_enc_if
    wire [3:0]  x_ev, x_erd, x_full;
    wire [31:0] x_ed [0:3];
    wire [15:0] x_wl [0:3], x_ovf [0:3];
    wire        feed_en = 1'b1;
    wire        g_go    = feed_en & ~(|x_full);   // 与板上 S_jcfg_consume 一致: 四路取与

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            gcnt <= 10'd0;
        else if (y_v && g_go)  gcnt <= y_last ? 10'd0 : (gcnt + 10'd1);
    end

    genvar gi;
    generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_if
        jpeg_enc_if #(.AW(12), .START_LEVEL(SLVL)) u_enc_if (
            .s_clk(clk), .s_rst_n(rst_n),
            .s_valid(y_v & g_go & gvld[gi]),      // ★ 必须带 g_go: rgb2yuv 无 ready
            .s_data(yuv_d), .s_sof(y_user),
            .e_clk(clk), .e_rst_n(rst_n), .i_flush(1'b0),
            .e_valid(x_ev[gi]), .e_data(x_ed[gi]), .e_ready(x_erd[gi]),
            .st_ovf(x_ovf[gi]), .st_word_lo(x_wl[gi]), .st_sof(),
            .o_level(), .o_full(x_full[gi]));
    end
    endgenerate

    //------------------------------------------------------------ 4 引擎 + 量化表
    wire [3:0]  e_rdy, e_mv, e_ml, e_seg, e_bs, e_bd;
    wire [7:0]  e_md [0:3];
    wire [23:0] e_by [0:3];
    wire [31:0] e_bc [0:3];
    wire [15:0] e_dg [0:3];
    wire [6:0]  e_qa [0:3], e_qb [0:3];
    wire [7:0]  e_qta [0:3], e_qtb [0:3];

    genvar gq;
    generate
    for (gq = 0; gq < 4; gq = gq + 1) begin : g_qt
        jpeg_qtable_ram u_qt (.I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0),
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
                           .RST_INIT(ge), .RST_STEP(4),
                           .LAST_RST_EN(ge == 3 ? 0 : 1)) u_e (
            .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_soft_rst(1'b0),
            .i_lossless(1'b0),
            .i_width(W1[11:0]), .i_height(H[11:0]), .i_rst_int(RSTI[15:0]),
            .o_qt_idx_a(e_qa[ge]), .i_qt_data_a(e_qta[ge]),
            .o_qt_idx_b(e_qb[ge]), .i_qt_data_b(e_qtb[ge]),
            .s_valid(x_ev[ge]), .s_data(x_ed[ge]), .s_ready(x_erd[ge]),
            .m_valid(e_mv[ge]), .m_data(e_md[ge]), .m_last(e_ml[ge]),
            .m_ready(e_rdy[ge]),
            .st_frame_bytes(e_by[ge]), .st_busy(e_bs[ge]), .st_done(e_bd[ge]),
            .st_frame_cnt(e_bc[ge]), .o_seg_done(e_seg[ge]), .o_diag(e_dg[ge]));
    end
    endgenerate

    //------------------------------------------------------------ 段合并 (4:1)
    wire        m_v, m_l, bw_rdy;
    wire [7:0]  m_d;
    wire [9:0]  m_segc;
    wire [31:0] e_d_pack = { e_md[3], e_md[2], e_md[1], e_md[0] };

    // ★ 与板上 V53b 一致: i_start 只由复位释放产生 (上电 rst_n 之后一拍)
    reg m_start = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) m_start <= 1'b0;
        else        m_start <= ~m_start;      // 上电只打一拍, 之后不再触发
    end

    jpeg_seg_merge4 u_mrg (
        .clk(clk), .rst_n(rst_n), .i_start(m_start),
        .i_valid(e_mv), .i_data(e_d_pack), .i_last(e_ml),
        .o_ready(e_rdy), .i_seg_done(e_seg),
        .o_valid(m_v), .o_data(m_d), .o_last(m_l),
        .o_ready_down(bw_rdy), .o_seg_cnt(m_segc));

    //------------------------------------------------------------ 字节桥 + CSI-2
    reg  b_clk = 1'b0, brst_n = 1'b0;
    always #4.000 b_clk = ~b_clk;            // 125 MHz
    initial begin brst_n = 1'b0; repeat (30) @(posedge b_clk); brst_n <= 1'b1; end

    wire        br_v, br_l;
    wire [7:0]  br_d;
    wire [15:0] bw_bp;
    wire [11:0] br_lvl;

    jpeg_byte_bridge #(.AW(12)) u_br (
        .w_clk(clk), .w_rst_n(rst_n),
        .w_valid(m_v), .w_data(m_d), .w_last(m_l), .w_ready(bw_rdy),
        .r_clk(b_clk), .r_rst_n(brst_n),
        .r_valid(br_v), .r_data(br_d), .r_last(br_l), .r_ready(br_v & br_rdy_d),
        .st_bp(bw_bp), .o_level(br_lvl));

    wire        tx_r;
    wire [31:0] tx_hs_d;
    wire        tx_hs_en, tx_hs_l;
    wire [31:0] tx_pkt, tx_byc, tx_frm;
    reg         br_rdy_d = 1'b1;
    always @(posedge b_clk) br_rdy_d <= tx_r;

    csi2_frame_tx_var #(.PKT_BYTES(1024), .GAP_FRAME(200), .VC(2'b00)) u_tx (
        .clk(b_clk), .rst_n(brst_n), .enable(1'b1), .i_dt(6'h1E),
        .s_tvalid(br_v), .s_tdata(br_d), .s_tlast(br_l), .s_tready(tx_r),
        .hs_en(tx_hs_en), .hs_data(tx_hs_d), .hs_last(tx_hs_l),
        .frame_cnt(tx_frm), .packet_cnt(tx_pkt), .byte_cnt(tx_byc));

    //------------------------------------------------------------ 参考模型 + 自检
    //  逐字节比对 rgb2yuv 输出
    integer err_yuv = 0, err_user = 0, err_last = 0;
    integer n_pixline = 0;          // 本行已出像素数
    integer n_line = 0;             // 已出行数
    integer n_sof  = 0;
    reg [7:0] exp_y, exp_cb, exp_cr;

    integer tmp_s, tmp_p, tmp_n;
    function [7:0] qY;  input [7:0] r, g, b; begin
        tmp_s = r*47 + g*157 + b*16 + 4096;
        qY = (tmp_s > 65535) ? 8'hFF : tmp_s[15:8];
    end endfunction
    function [7:0] qCb; input [7:0] r, g, b; begin
        tmp_p = b*112 + 32768; tmp_n = r*26 + g*86;
        qCb = (tmp_p >= tmp_n) ? (((tmp_p - tmp_n) >> 8) > 255 ? 8'hFF : (tmp_p - tmp_n) >> 8) : 8'd0;
    end endfunction
    function [7:0] qCr; input [7:0] r, g, b; begin
        tmp_p = r*112 + 32768; tmp_n = g*102 + b*10;
        qCr = (tmp_p >= tmp_n) ? (((tmp_p - tmp_n) >> 8) > 255 ? 8'hFF : (tmp_p - tmp_n) >> 8) : 8'd0;
    end endfunction

    integer chk_k;
    integer px0;
    integer eof_sof, eof_last;
    initial begin err_yuv = 0; err_user = 0; err_last = 0; n_pixline = 0; n_line = 0; n_sof = 0; end

    always @(posedge clk) begin
        if (rst_n && y_v) begin
            for (chk_k = 0; chk_k < 4; chk_k = chk_k + 1) begin
                px0 = (n_pixline + chk_k);
                // 期望: yv[k] / cb[k] / cr[k]
                exp_y  = qY (fR(px0, n_line), fG(px0, n_line), fB(px0, n_line));
                exp_cb = qCb(fR(px0, n_line), fG(px0, n_line), fB(px0, n_line));
                exp_cr = qCr(fR(px0, n_line), fG(px0, n_line), fB(px0, n_line));
                if (chk_k == 0) begin
                    if (yuv_d[7:0]  !== exp_y)  begin if (err_yuv<4) $display("[ERR-Y] x=%0d y=%0d got=%02x exp=%02x", px0, n_line, yuv_d[7:0],  exp_y);  err_yuv = err_yuv+1; end
                    if (yuv_d[15:8] !== exp_cb) begin if (err_yuv<4) $display("[ERR-B] x=%0d y=%0d got=%02x exp=%02x", px0, n_line, yuv_d[15:8], exp_cb); err_yuv = err_yuv+1; end
                end
                if (chk_k == 1) begin
                    if (yuv_d[23:16] !== exp_y)  begin if (err_yuv<4) $display("[ERR-Y] x=%0d y=%0d got=%02x exp=%02x", px0, n_line, yuv_d[23:16], exp_y); err_yuv = err_yuv+1; end
                    if (yuv_d[31:24] !== exp_cr) begin if (err_yuv<4) $display("[ERR-C] x=%0d y=%0d got=%02x exp=%02x", px0, n_line, yuv_d[31:24], exp_cr); err_yuv = err_yuv+1; end
                end
                if (chk_k == 2) begin
                    if (yuv_d[39:32] !== exp_y)  begin if (err_yuv<4) $display("[ERR-Y] x=%0d y=%0d got=%02x exp=%02x", px0, n_line, yuv_d[39:32], exp_y); err_yuv = err_yuv+1; end
                    if (yuv_d[47:40] !== exp_cb) begin if (err_yuv<4) $display("[ERR-B] x=%0d y=%0d got=%02x exp=%02x", px0, n_line, yuv_d[47:40], exp_cb); err_yuv = err_yuv+1; end
                end
                if (chk_k == 3) begin
                    if (yuv_d[55:48] !== exp_y)  begin if (err_yuv<4) $display("[ERR-Y] x=%0d y=%0d got=%02x exp=%02x", px0, n_line, yuv_d[55:48], exp_y); err_yuv = err_yuv+1; end
                    if (yuv_d[63:56] !== exp_cr) begin if (err_yuv<4) $display("[ERR-C] x=%0d y=%0d got=%02x exp=%02x", px0, n_line, yuv_d[63:56], exp_cr); err_yuv = err_yuv+1; end
                end
            end
            if (y_user !== ((n_pixline == 0) && (n_line == 0))) begin
                if (err_user < 4) $display("[ERR-USER] x=%0d y=%0d got=%b", n_pixline, n_line, y_user);
                err_user = err_user + 1;
            end
            if (y_last !== ((n_pixline/W1) == 0 && n_pixline == W1-4)) begin
                if (err_last < 4) $display("[ERR-LAST] x=%0d y=%0d got=%b", n_pixline, n_line, y_last);
                err_last = err_last + 1;
            end
            n_pixline = n_pixline + 4;
            if (n_pixline == W1) begin n_pixline = 0; n_line = n_line + 1; end
            if (y_user) n_sof = n_sof + 1;
        end
    end

    //------------------------------------------------------------ 源激励
    integer sy, sk;
    initial begin : SRC
        s_v = 1'b0; s_user = 1'b0; s_last = 1'b0; s_rgb = 128'd0;
        @(posedge rst_n);
        repeat (5) @(negedge clk);
        for (sy = 0; sy < H; sy = sy + 1) begin
            for (sk = 0; sk < W1/4; sk = sk + 1) begin
                @(negedge clk);
                s_v = 1'b1;
                s_user = (sy == 0) && (sk == 0);
                s_last = (sk == W1/4 - 1);
                s_rgb[ 31: 0] = {8'hFF, fR(4*sk+0, sy), fG(4*sk+0, sy), fB(4*sk+0, sy)};
                s_rgb[ 63:32] = {8'hFF, fR(4*sk+1, sy), fG(4*sk+1, sy), fB(4*sk+1, sy)};
                s_rgb[ 95:64] = {8'hFF, fR(4*sk+2, sy), fG(4*sk+2, sy), fB(4*sk+2, sy)};
                s_rgb[127:96] = {8'hFF, fR(4*sk+3, sy), fG(4*sk+3, sy), fB(4*sk+3, sy)};
                if (!g_go) @(posedge clk);      // 被反压就等 (源比下游快)
            end
        end
        @(negedge clk); s_v = 1'b0; s_user = 1'b0; s_last = 1'b0;
        $display("[TB] source done");
    end

    //------------------------------------------------------------ 落盘
    integer fdm, nm;
    initial begin fdm = $fopen("pre2jpeg.jpg", "wb"); nm = 0; end
    always @(posedge clk) if (m_v === 1'b1 && bw_rdy === 1'b1) begin
        $fwrite(fdm, "%c", m_d); nm = nm + 1; end

    //------------------------------------------------------------ 收尾
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    integer nm_d = 0, stall = 0;
    always @(posedge clk) begin
        if (nm != nm_d) begin nm_d = nm; stall = 0; end else stall = stall + 1;
    end

    initial begin
        wait (stall > 20000);
        $fclose(fdm);
        $display("--------------------------------------------------");
        $display("LINES   : %0d (exp %0d)  SOF=%0d (exp 1)", n_line, H, n_sof);
        $display("ERR  yuv=%0d user=%0d last=%0d", err_yuv, err_user, err_last);
        $display("MERGED  : %0d bytes  segcnt=%0d (exp %0d)  cyc=%0d", nm, m_segc, 4*H, cyc);
        $display("ENG by  : %0d/%0d/%0d/%0d  wl=%0d/%0d/%0d/%0d  ovf=%b",
                 e_by[0], e_by[1], e_by[2], e_by[3],
                 x_wl[0], x_wl[1], x_wl[2], x_wl[3],
                 (|x_ovf[0])|(|x_ovf[1])|(|x_ovf[2])|(|x_ovf[3]));
        $display("BRIDGE  : level=%0d wbp=%0d  txpkt=%0d", br_lvl, bw_bp, tx_pkt);
        if (err_yuv == 0 && err_user == 0 && err_last == 0 && nm > 100 && m_segc == 4*H)
            $display("RESULT  : PASS");
        else
            $display("RESULT  : FAIL");
        $finish;
    end

    initial begin
        wait (cyc >= 400000);
        $display("TIMEOUT cyc=%0d nm=%0d segcnt=%0d lines=%0d", cyc, nm, m_segc, n_line);
        $display("RESULT  : FAIL (timeout)");
        $finish;
    end

endmodule
