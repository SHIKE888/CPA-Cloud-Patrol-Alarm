/*===========================================================================
 * tb_eif1.v —— jpeg_enc_if 隔离测试
 *
 *   源 (64b): word n = { 晚32b = n*2+1, 早32b = n*2 }   (早像素在低半)
 *   期望引擎收到的 32b 序列: 2n, 2n+1, 2n+2, 2n+3, ...
 *   即 lo(0), hi(0), lo(1), hi(1), ...
 *==========================================================================*/
`timescale 1ns / 1ps

module tb_eif1;

    localparam integer NW = 300;   // 64b 字数

    reg clk, rst_n;
    initial begin clk = 1'b0; rst_n = 1'b0; end
    always #5 clk = ~clk;

    reg         s_v;
    reg  [63:0] s_d;
    reg         s_sof;

    wire        e_v;
    wire [31:0] e_d;
    reg         e_rdy;
    wire [15:0] st_ovf, st_wl, st_sof;
    wire [9:0]  lvl;

    initial e_rdy = 1'b0;

    jpeg_enc_if #(.AW(10)) u_eif (
        .s_clk(clk), .s_rst_n(rst_n),
        .s_valid(s_v), .s_data(s_d), .s_sof(s_sof),
        .e_clk(clk), .e_rst_n(rst_n),
        .i_flush(1'b0),
        .e_valid(e_v), .e_data(e_d), .e_ready(e_rdy),
        .st_ovf(st_ovf), .st_word_lo(st_wl), .st_sof(st_sof), .o_level(lvl)
    );

    function [31:0] w32; input integer i; begin w32 = { i[15:0], i[15:0] }; end endfunction

    // 源: 背靠背写入, 尊重 full (这里靠 s_v 常高 + 检查 st_ovf)
    integer n_wr = 0;
    initial begin : SRC
        integer n;
        s_v = 1'b0; s_d = 64'd0; s_sof = 1'b0;
        @(posedge rst_n);
        repeat (6) @(negedge clk);
        for (n = 0; n < NW; n = n + 1) begin
            @(negedge clk);
            s_v   = 1'b1;
            s_sof = (n == 0);
            s_d   = { w32(2*n+1), w32(2*n) };
            n_wr  = n_wr + 1;
        end
        @(negedge clk); s_v = 1'b0; s_sof = 1'b0;
        $display("[SRC] wrote %0d 64b words", n_wr);
    end

    // 检查
    integer got = 0, err = 0;
    always @(posedge clk) begin
        if (rst_n && e_v && e_rdy) begin
            if (e_d !== w32(got)) begin
                if (err < 12)
                    $display("[ERR] #%0d got=%h exp=%h", got, e_d, w32(got));
                err = err + 1;
            end
            got = got + 1;
        end
    end

    initial begin
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (20) @(negedge clk);
        e_rdy = 1'b1;
        $display("[TB] e_ready on");
        wait (n_wr == NW);
        repeat (NW*4 + 200) @(negedge clk);
        $display("--------------------------------------------------");
        $display("wrote=%0d words (%0d x 32b)  got=%0d  exp=%0d",
                 n_wr, n_wr*2, got, NW*2);
        $display("st_ovf=%0d  st_word_lo=%0d  st_sof=%0d  level=%0d",
                 st_ovf, st_wl, st_sof, lvl);
        $display("ERR=%0d", err);
        if (err == 0 && got == NW*2 && st_ovf == 0) $display("EIF1 PASS");
        else                                        $display("EIF1 FAIL");
        $finish;
    end

    initial begin #2000000; $display("TIMEOUT got=%0d", got); $finish; end

endmodule
