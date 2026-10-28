/*===========================================================================
 * tb_jpeg_merge4.v ?????????1/4 ??????????????
 *
 *  ???: ??? [???0(128?? + ???1(128?? + ???2 + ???3] ??jpeg_seg_merge4
 *        ???????? ??[??? 512 ?????+ DRI] ?????**????????*??
 *
 *  ???: 512 ??= 32 MCU/?? DRI=8 -> ??8 MCU(1/4 ?? ??????????
 *        ??? k ????????k ??1/4 ??(8 MCU)??
 *        RST ???: ??? k ??? = k, ??? = 4  -> 0,1,2,3, 4,5,6,7, 0,1,2,3...
 *        ??????????????0,1,2,3,4,5,6,7... ?????????
 *        ?????????????????(???/DCT/??????????
 *
 *  ???: merged4.jpg (?????, ref4.jpg (????????
 *==========================================================================*/
`timescale 1ns / 1ps

module tb_m4_dbg;

    localparam integer W4   = 128;   // ????????? (128/16 = 8 MCU/??
    localparam integer H    = 32;
    localparam integer W1   = 512;   // ???????????
    localparam integer RSTI = 8;     // = W4/16, ??1/4 ?????????

    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.3 clk = ~clk;

    //--------------------------------------------------------------- ????????
    wire [3:0]  e_rdy;
    reg  [3:0]  e_v;
    reg  [31:0] e_d [0:3];
    wire [3:0]  e_mv, e_ml, e_seg, e_bs, e_bd;
    wire [7:0]  e_md [0:3];
    wire [23:0] e_by [0:3];
    wire [31:0] e_bc [0:3];

    //--------------------------------------------------------------- ????????
    reg  [31:0] f_d;
    reg         f_v;
    wire        f_rdy, f_mv, f_ml, f_seg, f_bs, f_bd;
    wire [7:0]  f_md;
    wire [23:0] f_by;
    wire [31:0] f_bc;

    //--------------------------------------------------------------- ?????
    wire [6:0]  e_qa [0:3];
    wire [6:0]  e_qb [0:3];
    wire [7:0]  e_qta [0:3];
    wire [7:0]  e_qtb [0:3];
    wire [6:0]  f_qa, f_qb;
    wire [7:0]  f_qta, f_qtb;

    genvar gq;
    generate
    for (gq = 0; gq < 4; gq = gq + 1) begin : g_qt
        jpeg_qtable_ram u_qt (.I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0), .I_wr_addr(8'd0),
            .I_wr_data(8'd0), .I_rd_idx_a(e_qa[gq]), .O_rd_data_a(),
            .O_rd_data_a_asyn(e_qta[gq]),
            .I_rd_idx_b(e_qb[gq]), .O_rd_data_b(e_qtb[gq]));
    end
    endgenerate

    jpeg_qtable_ram u_qtf (.I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0), .I_wr_addr(8'd0),
        .I_wr_data(8'd0), .I_rd_idx_a(f_qa), .O_rd_data_a(), .O_rd_data_a_asyn(f_qta),
        .I_rd_idx_b(f_qb), .O_rd_data_b(f_qtb));

    //--------------------------------------------------------------- ??????
    //   ???0 ????? ???3 ??EOI; ???????????
    //   RST_INIT = k, RST_STEP = 4  -> 0,1,2,3 ???
    genvar ge;
    generate
    for (ge = 0; ge < 4; ge = ge + 1) begin : g_enc
        jpeg_encoder_top #(.W(W4), .H(H),
                           .HDR_EN(ge == 0 ? 1 : 0),
                           .EOI_EN(ge == 3 ? 1 : 0),
                           .RST_INIT(ge),
                           .RST_STEP(4),
                           .LAST_RST_EN(ge == 3 ? 0 : 1)) u_e (
            .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_soft_rst(1'b0), .i_lossless(1'b0),
            .i_width(W1[11:0]), .i_height(H[11:0]), .i_rst_int(RSTI[15:0]),
            .o_qt_idx_a(e_qa[ge]), .i_qt_data_a(e_qta[ge]),
            .o_qt_idx_b(e_qb[ge]), .i_qt_data_b(e_qtb[ge]),
            .s_valid(e_v[ge]), .s_data(e_d[ge]), .s_ready(e_rdy[ge]),
            .m_valid(e_mv[ge]), .m_data(e_md[ge]), .m_last(e_ml[ge]),
            .m_ready(1'b1),   // ??merge4 ??o_ready ?????? (wire [3:0] e_rdy)
            .st_frame_bytes(e_by[ge]), .st_busy(e_bs[ge]), .st_done(e_bd[ge]),
            .st_frame_cnt(e_bc[ge]), .o_seg_done(e_seg[ge]));
    end
    endgenerate

    //--------------------------------------------------------------- ????????
    jpeg_encoder_top #(.W(W1), .H(H), .HDR_EN(1), .EOI_EN(1),
                       .RST_INIT(0), .RST_STEP(1), .LAST_RST_EN(0)) u_f (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_soft_rst(1'b0), .i_lossless(1'b0),
        .i_width(W1[11:0]), .i_height(H[11:0]), .i_rst_int(RSTI[15:0]),
        .o_qt_idx_a(f_qa), .i_qt_data_a(f_qta), .o_qt_idx_b(f_qb), .i_qt_data_b(f_qtb),
        .s_valid(f_v), .s_data(f_d), .s_ready(f_rdy),
        .m_valid(f_mv), .m_data(f_md), .m_last(f_ml), .m_ready(1'b1),
        .st_frame_bytes(f_by), .st_busy(f_bs), .st_done(f_bd), .st_frame_cnt(f_bc),
        .o_seg_done(f_seg));

    //--------------------------------------------------------------- ?????(4:1)
    wire        m_v, m_l;
    wire [7:0]  m_d;
    wire [9:0]  m_segc;
    reg         m_start;

    wire [31:0] e_d_pack = { e_d[3], e_d[2], e_d[1], e_d[0] };

    jpeg_seg_merge4 u_mrg (
        .clk(clk), .rst_n(rst_n), .i_start(m_start),
        .i_valid(e_mv), .i_data(e_d_pack), .i_last(e_ml),
        .o_ready(e_rdy),                    // 4 ??????????????? m_ready
        .i_seg_done(e_seg),
        .o_valid(m_v), .o_data(m_d), .o_last(m_l), .o_ready_down(1'b1),
        .o_seg_cnt(m_segc));

    //--------------------------------------------------------------- ??????
    function [7:0] pY;  input integer x, y; begin pY  = (x*3  + y*7 ) & 8'hFF; end endfunction
    function [7:0] pCb; input integer x, y; begin pCb = (x*5  + y*13) & 8'hFF; end endfunction
    function [7:0] pCr; input integer x, y; begin pCr = (x*11 + y*3 ) & 8'hFF; end endfunction

    function [31:0] mkword; input integer x0, y; begin
        mkword = { pCr(x0,y), pY(x0+1,y), pCb(x0,y), pY(x0,y) };
    end endfunction

    //--------------------------------------------------------------- ??? (4 ??+ ????
    //  ???????negedge ?????1 ?????ready ????posedge ?????? DUT ??????
    genvar gf;
    generate
    for (gf = 0; gf < 4; gf = gf + 1) begin : g_feed
        initial begin : FEED
            integer yy, k;
            e_v[gf] = 1'b0; e_d[gf] = 32'd0;
            @(posedge rst_n); repeat (4) @(negedge clk);
            for (yy = 0; yy < H; yy = yy + 1)
                for (k = 0; k < W4/2; k = k + 1) begin
                    @(negedge clk); e_v[gf] = 1'b1;
                    e_d[gf] = mkword(gf*W4 + 2*k, yy); #1;
                    while (!e_rdy[gf]) begin @(negedge clk); #1; end
                end
            @(negedge clk); e_v[gf] = 1'b0;
            $display("[TB] engine %0d feed done", gf);
        end
    end
    endgenerate

    initial begin : FEED_F
        integer yy, k;
        f_v = 1'b0; f_d = 32'd0;
        @(posedge rst_n); repeat (4) @(negedge clk);
        for (yy = 0; yy < H; yy = yy + 1)
            for (k = 0; k < W1/2; k = k + 1) begin
                @(negedge clk); f_v = 1'b1; f_d = mkword(2*k, yy); #1;
                while (!f_rdy) begin @(negedge clk); #1; end
            end
        @(negedge clk); f_v = 1'b0;
        $display("[TB] ref feed done");
    end

    //--------------------------------------------------------------- ????????
    integer fdm, fdf, nm, nf;
    initial begin
        fdm = $fopen("merged4.jpg", "wb");
        fdf = $fopen("ref4.jpg",   "wb");
        nm = 0; nf = 0;
    end
    always @(posedge clk) if (m_v === 1'b1) begin $fwrite(fdm, "%c", m_d); nm = nm + 1; end
    always @(posedge clk) if (f_mv === 1'b1) begin $fwrite(fdf, "%c", f_md); nf = nf + 1; end

    reg fd_f, m_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fd_f <= 1'b0; m_seen <= 1'b0; end
        else begin
            if (f_bd) fd_f  <= 1'b1;
            if (m_l)  m_seen<= 1'b1;
        end
    end

    // ---- ???: ???????????? ----
    integer nseg4 = 0;
    always @(posedge clk) if (e_seg[0] || e_seg[1] || e_seg[2] || e_seg[3]) begin
        nseg4 = nseg4 + 1;
        if (nseg4 <= 24)
            $display("[TB] t=%0t seg=%b rdy=%b msegc=%0d", $time, e_seg, e_rdy, m_segc);
    end

    initial begin
        m_start = 1'b0;
        rst_n   = 1'b0;
        #100;
        rst_n = 1'b1;
        @(negedge clk); m_start = 1'b1;
        @(negedge clk); m_start = 1'b0;
    end

    initial begin
        wait (fd_f === 1'b1);
        #20000;
        $fclose(fdm);
        $fclose(fdf);
        $display("MERGED4: %0d bytes, segcnt=%0d, last_seen=%b", nm, m_segc, m_seen);
        $display("REF4   : %0d bytes", nf);
        $display("STATS e0=%0d e1=%0d e2=%0d e3=%0d | ref=%0d",
                 e_by[0], e_by[1], e_by[2], e_by[3], f_by);
        if (nm == nf && nm > 0) $display("SIZE MATCH");
        else                    $display("SIZE MISMATCH !!!");
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT merged=%0d ref=%0d", nm, nf);
        $fclose(fdm); $fclose(fdf);
        $finish;
    end

endmodule
