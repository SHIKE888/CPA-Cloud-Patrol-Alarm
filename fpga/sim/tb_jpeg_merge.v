/*===========================================================================
 * tb_jpeg_merge.v —— 双引擎"半行段"合并等价性验证
 *
 *  目的: 证明 [左引擎(256宽) + 右引擎(256宽)] 经 jpeg_seg_merge 交替拼接后,
 *        与 [单个 512 宽引擎 + DRI] 的输出**逐字节相同**。
 *
 *  原理: 512 宽 = 32 MCU/行, DRI=16 -> 每 16 MCU(半个行)一个重启段。
 *        左引擎负责每行前 16 MCU, 右引擎负责后 16 MCU。
 *        RST 编号: 左 0,2,4,6 (LAST_RST_EN=1), 右 1,3,5 (LAST_RST_EN=0),
 *        交错后正好是 0,1,2,3,4,5,6 —— 与单引擎完全一致。
 *        于是两者应当字节级相同(头/量化/DCT/熵编码全同)。
 *
 *  产物: merged.jpg (双引擎), ref.jpg2 (单引擎参考)
 *==========================================================================*/
`timescale 1ns / 1ps

module tb_jpeg_merge;

    localparam integer W2   = 256;   // 每个引擎的宽
    localparam integer H    = 32;
    localparam integer W1   = 512;   // 参考单引擎的宽
    localparam integer RSTI = 16;    // = W2/16, 每半个行一个重启段

    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.3 clk = ~clk;

    //--------------------------------------------------------------- 输入
    reg  [31:0] a_d, b_d, f_d;
    reg         a_v, b_v, f_v;
    wire        a_rdy, b_rdy, f_rdy;

    //--------------------------------------------------------------- 输出
    wire        a_mv, b_mv, f_mv;
    wire [7:0]  a_md, b_md, f_md;
    wire        a_ml, b_ml, f_ml;
    wire        a_seg, b_seg, f_seg;
    wire [23:0] a_by, b_by, f_by;
    wire        a_bs, b_bs, f_bs, a_bd, b_bd, f_bd;
    wire [31:0] a_bc, b_bc, f_bc;

    //--------------------------------------------------------------- 量化表
    wire [6:0]  a_qa, b_qa, f_qa, a_qb, b_qb, f_qb;
    wire [7:0]  a_qta, b_qta, f_qta, a_qtb, b_qtb, f_qtb;

    jpeg_qtable_ram u_qta (.I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0), .I_wr_addr(8'd0),
        .I_wr_data(8'd0), .I_rd_idx_a(a_qa), .O_rd_data_a(), .O_rd_data_a_asyn(a_qta),
        .I_rd_idx_b(a_qb), .O_rd_data_b(a_qtb));
    jpeg_qtable_ram u_qtb (.I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0), .I_wr_addr(8'd0),
        .I_wr_data(8'd0), .I_rd_idx_a(b_qa), .O_rd_data_a(), .O_rd_data_a_asyn(b_qta),
        .I_rd_idx_b(b_qb), .O_rd_data_b(b_qtb));
    jpeg_qtable_ram u_qtf (.I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0), .I_wr_addr(8'd0),
        .I_wr_data(8'd0), .I_rd_idx_a(f_qa), .O_rd_data_a(), .O_rd_data_a_asyn(f_qta),
        .I_rd_idx_b(f_qb), .O_rd_data_b(f_qtb));

    //--------------------------------------------------------------- 合并器输出
    wire       m_v;
    wire [7:0] m_d;
    wire       m_l;
    wire       l_rdy;      // 合并器 -> 左引擎 m_ready
    wire       r_rdy;      // 合并器 -> 右引擎 m_ready
    wire [9:0] m_segc;
    reg        m_start;
    reg        en_a = 1'b1;
    reg        en_b = 1'b1;
    reg        en_f = 1'b1;

    //--------------------------------------------------------------- 左引擎
    jpeg_encoder_top #(.W(W2), .H(H), .HDR_EN(1), .EOI_EN(0),
                       .RST_INIT(0), .RST_STEP(2), .LAST_RST_EN(1)) u_a (
        .clk(clk), .rst_n(rst_n), .i_en(en_a), .i_soft_rst(1'b0), .i_lossless(1'b0),
        .i_width(W1[11:0]), .i_height(H[11:0]), .i_rst_int(RSTI[15:0]),
        .o_qt_idx_a(a_qa), .i_qt_data_a(a_qta), .o_qt_idx_b(a_qb), .i_qt_data_b(a_qtb),
        .s_valid(a_v), .s_data(a_d), .s_ready(a_rdy),
        .m_valid(a_mv), .m_data(a_md), .m_last(a_ml), .m_ready(l_rdy),
        .st_frame_bytes(a_by), .st_busy(a_bs), .st_done(a_bd), .st_frame_cnt(a_bc),
        .o_seg_done(a_seg));

    //--------------------------------------------------------------- 右引擎
    jpeg_encoder_top #(.W(W2), .H(H), .HDR_EN(0), .EOI_EN(1),
                       .RST_INIT(1), .RST_STEP(2), .LAST_RST_EN(0)) u_b (
        .clk(clk), .rst_n(rst_n), .i_en(en_b), .i_soft_rst(1'b0), .i_lossless(1'b0),
        .i_width(W1[11:0]), .i_height(H[11:0]), .i_rst_int(RSTI[15:0]),
        .o_qt_idx_a(b_qa), .i_qt_data_a(b_qta), .o_qt_idx_b(b_qb), .i_qt_data_b(b_qtb),
        .s_valid(b_v), .s_data(b_d), .s_ready(b_rdy),
        .m_valid(b_mv), .m_data(b_md), .m_last(b_ml), .m_ready(r_rdy),
        .st_frame_bytes(b_by), .st_busy(b_bs), .st_done(b_bd), .st_frame_cnt(b_bc),
        .o_seg_done(b_seg));

    //--------------------------------------------------------------- 参考单引擎
    jpeg_encoder_top #(.W(W1), .H(H), .HDR_EN(1), .EOI_EN(1),
                       .RST_INIT(0), .RST_STEP(1), .LAST_RST_EN(0)) u_f (
        .clk(clk), .rst_n(rst_n), .i_en(en_f), .i_soft_rst(1'b0), .i_lossless(1'b0),
        .i_width(W1[11:0]), .i_height(H[11:0]), .i_rst_int(RSTI[15:0]),
        .o_qt_idx_a(f_qa), .i_qt_data_a(f_qta), .o_qt_idx_b(f_qb), .i_qt_data_b(f_qtb),
        .s_valid(f_v), .s_data(f_d), .s_ready(f_rdy),
        .m_valid(f_mv), .m_data(f_md), .m_last(f_ml), .m_ready(1'b1),
        .st_frame_bytes(f_by), .st_busy(f_bs), .st_done(f_bd), .st_frame_cnt(f_bc),
        .o_seg_done(f_seg));

    //--------------------------------------------------------------- 合并器
    jpeg_seg_merge u_mrg (
        .clk(clk), .rst_n(rst_n), .i_start(m_start),
        .l_valid(a_mv), .l_data(a_md), .l_last(a_ml), .l_ready(l_rdy), .l_seg_done(a_seg),
        .r_valid(b_mv), .r_data(b_md), .r_last(b_ml), .r_ready(r_rdy), .r_seg_done(b_seg),
        .o_valid(m_v), .o_data(m_d), .o_last(m_l), .o_ready(1'b1),
        .o_seg_cnt(m_segc));

    //--------------------------------------------------------------- 像素图案
    function [7:0] pY;  input integer x, y; begin pY  = (x*3  + y*7 ) & 8'hFF; end endfunction
    function [7:0] pCb; input integer x, y; begin pCb = (x*5  + y*13) & 8'hFF; end endfunction
    function [7:0] pCr; input integer x, y; begin pCr = (x*11 + y*3 ) & 8'hFF; end endfunction

    // word = {Cr, Y1, Cb, Y0}, 覆盖像素 x0 和 x0+1
    function [31:0] mkword; input integer x0, y; begin
        mkword = { pCr(x0,y), pY(x0+1,y), pCb(x0,y), pY(x0,y) };
    end endfunction

        //--------------------------------------------------------------- 送数
    //  ★ 必须在 negedge 驱动、#1 之后看 ready —— posedge 驱动会和 DUT 采样抢拍

    initial begin : FEED_A
        integer yy, k;
        reg [31:0] dw;
        a_v = 1'b0; a_d = 32'd0;
        @(posedge rst_n); repeat (4) @(negedge clk);
        for (yy = 0; yy < H; yy = yy + 1)
            for (k = 0; k < W2/2; k = k + 1) begin
                @(negedge clk); a_v = 1'b1; a_d = mkword(2*k, yy); #1;
                while (!a_rdy) begin @(negedge clk); #1; end
            end
        @(negedge clk); a_v = 1'b0;
        $display("[TB] A done");
    end

    initial begin : FEED_B
        integer yy, k;
        reg [31:0] dw;
        b_v = 1'b0; b_d = 32'd0;
        @(posedge rst_n); repeat (4) @(negedge clk);
        for (yy = 0; yy < H; yy = yy + 1)
            for (k = 0; k < W2/2; k = k + 1) begin
                @(negedge clk); b_v = 1'b1; b_d = mkword(W2 + 2*k, yy); #1;
                while (!b_rdy) begin @(negedge clk); #1; end
            end
        @(negedge clk); b_v = 1'b0;
        $display("[TB] B done");
    end

    initial begin : FEED_F
        integer yy, k;
        reg [31:0] dw;
        f_v = 1'b0; f_d = 32'd0;
        @(posedge rst_n); repeat (4) @(negedge clk);
        for (yy = 0; yy < H; yy = yy + 1)
            for (k = 0; k < W1/2; k = k + 1) begin
                @(negedge clk); f_v = 1'b1; f_d = mkword(2*k, yy); #1;
                while (!f_rdy) begin @(negedge clk); #1; end
            end
        @(negedge clk); f_v = 1'b0;
        $display("[TB] F done");
    end

    //--------------------------------------------------------------- 输出到文件
    integer fdm, fdf, nm, nf;
    initial begin
        fdm = $fopen("merged.jpg", "wb");
        fdf = $fopen("ref2.jpg",   "wb");
        nm = 0; nf = 0;
    end
    always @(posedge clk) if (m_v === 1'b1) begin $fwrite(fdm, "%c", m_d); nm = nm + 1; end
    always @(posedge clk) if (f_mv === 1'b1) begin $fwrite(fdf, "%c", f_md); nf = nf + 1; end

    // st_done 是脉冲, 必须粘住
    reg fd_b, fd_f, m_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fd_b <= 1'b0; fd_f <= 1'b0; m_seen <= 1'b0; end
        else begin
            if (a_bd) en_a <= 1'b0;
            if (b_bd) begin fd_b <= 1'b1; en_b <= 1'b0; end
            if (f_bd) begin fd_f <= 1'b1; en_f <= 1'b0; end
            if (m_l)  m_seen <= 1'b1;
        end
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
        wait (fd_b === 1'b1);
        wait (fd_f === 1'b1);
        #3000;
        $fclose(fdm);
        $fclose(fdf);
        $display("MERGED: %0d bytes, segcnt=%0d, last_seen=%b", nm, m_segc, m_seen);
        $display("REF   : %0d bytes", nf);
        $display("STATS A bytes=%0d frm=%0d | B bytes=%0d frm=%0d | F bytes=%0d frm=%0d",
                 a_by, a_bc, b_by, b_bc, f_by, f_bc);
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT merged=%0d ref=%0d", nm, nf);
        $fclose(fdm); $fclose(fdf);
        $finish;
    end

endmodule