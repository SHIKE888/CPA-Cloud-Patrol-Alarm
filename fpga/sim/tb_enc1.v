/*===========================================================================
 * tb_enc1.v —— 单引擎最小回环: 确认 W=128/H=32/RSTI=8 参数下编码器能完成一帧
 *   只回答一个问题: st_frame_bytes > 0 ? st_done 有没有脉冲 ?
 *==========================================================================*/
`timescale 1ns / 1ps

module tb_enc1;

    localparam integer WW   = 128;
    localparam integer HH   = 32;
    localparam integer RSTI = 8;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.3 clk = ~clk;

    reg  [31:0] s_d;
    reg         s_v;
    wire        s_rdy;
    wire        m_v, m_l;
    wire [7:0]  m_d;
    wire [23:0] by;
    wire        bs, bd;
    wire [31:0] bc;
    wire        seg;
    wire [6:0]  qa, qb;
    wire [7:0]  qta, qtb;

    jpeg_qtable_ram u_qt (.I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0), .I_wr_addr(8'd0),
        .I_wr_data(8'd0), .I_rd_idx_a(qa), .O_rd_data_a(), .O_rd_data_a_asyn(qta),
        .I_rd_idx_b(qb), .O_rd_data_b(qtb));

    jpeg_encoder_top #(.W(WW), .H(HH), .HDR_EN(1), .EOI_EN(1),
                       .RST_INIT(0), .RST_STEP(1), .LAST_RST_EN(0)) u_e (
        .clk(clk), .rst_n(rst_n), .i_en(1'b1), .i_soft_rst(1'b0), .i_lossless(1'b0),
        .i_width(WW[11:0]), .i_height(HH[11:0]), .i_rst_int(RSTI[15:0]),
        .o_qt_idx_a(qa), .i_qt_data_a(qta), .o_qt_idx_b(qb), .i_qt_data_b(qtb),
        .s_valid(s_v), .s_data(s_d), .s_ready(s_rdy),
        .m_valid(m_v), .m_data(m_d), .m_last(m_l), .m_ready(1'b1),
        .st_frame_bytes(by), .st_busy(bs), .st_done(bd), .st_frame_cnt(bc),
        .o_seg_done(seg));

    function [7:0] pY;  input integer x, y; begin pY  = (x*3  + y*7 ) & 8'hFF; end endfunction
    function [7:0] pCb; input integer x, y; begin pCb = (x*5  + y*13) & 8'hFF; end endfunction
    function [7:0] pCr; input integer x, y; begin pCr = (x*11 + y*3 ) & 8'hFF; end endfunction
    function [31:0] mkword; input integer x0, y; begin
        mkword = { pCr(x0,y), pY(x0+1,y), pCb(x0,y), pY(x0,y) };
    end endfunction

    integer nb, nseg;
    initial begin nb = 0; nseg = 0; end
    always @(posedge clk) if (m_v === 1'b1) nb = nb + 1;
    always @(posedge clk) if (seg  === 1'b1) nseg = nseg + 1;

    initial begin : FEED
        integer yy, k;
        s_v = 1'b0; s_d = 32'd0;
        @(posedge rst_n); repeat (4) @(negedge clk);
        for (yy = 0; yy < HH; yy = yy + 1)
            for (k = 0; k < WW/2; k = k + 1) begin
                @(negedge clk); s_v = 1'b1; s_d = mkword(2*k, yy); #1;
                while (!s_rdy) begin @(negedge clk); #1; end
            end
        @(negedge clk); s_v = 1'b0;
        $display("[TB] feed done");
    end

    reg bd_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bd_seen <= 1'b0;
        else if (bd) bd_seen <= 1'b1;
    end

    initial begin
        rst_n = 1'b0;
        #100;
        rst_n = 1'b1;
        wait (bd_seen === 1'b1);
        #500;
        $display("BYTES=%0d  FRAMES=%0d  SEG=%0d  LAST=%b  busy=%b done=%b",
                 by, bc, nseg, m_l, bs, bd);
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT bytes=%0d frames=%0d seg=%0d busy=%b", by, bc, nseg, bs);
        $finish;
    end

endmodule
