/*===========================================================================
 * tb_conv1.v —— yuv32_to_quad 隔离测试 (只测 32->64 拼装 + CDC FIFO)
 *
 *   源: 每个 32b 字 = {idx[31:16], idx[15:0]}, idx 从 0 递增
 *   期望: 第 n 个输出 64b = { word(2n+1), word(2n) }
 *        (早像素在低半, 晚像素在高半)
 *   同时检查 sof/last 只出现在正确位置。
 *==========================================================================*/
`timescale 1ns / 1ps

module tb_conv1;

    localparam integer NW   = 1024;   // 32b 字数 (= 512 个 64b 字)
    localparam integer LW   = 64;     // 每行 32b 字数 -> 32 个 64b 字/行

    reg r_clk, c_clk, rst_n;
    initial begin r_clk = 1'b0; c_clk = 1'b0; rst_n = 1'b0; end
    always #4.752 r_clk = ~r_clk;    // 105.2 MHz
    always #5.000 c_clk = ~c_clk;    // 100.0 MHz

    reg         r_v;
    reg  [31:0] r_d;
    reg         r_sof, r_last;
    wire        r_rdy;

    wire        c_v, c_sof, c_last;
    wire [63:0] c_d;
    reg         c_rdy;
    initial c_rdy = 1'b0;

    yuv32_to_quad u_conv (
        .r_clk(r_clk), .r_rst_n(rst_n),
        .r_valid(r_v), .r_data(r_d), .r_sof(r_sof), .r_last(r_last),
        .r_ready(r_rdy),
        .c_clk(c_clk), .c_rst_n(rst_n),
        .c_valid(c_v), .c_data(c_d), .c_sof(c_sof), .c_last(c_last),
        .c_ready(c_rdy)
    );

    function [31:0] w32; input integer i; begin w32 = { i[15:0], i[15:0] }; end endfunction

    //----------------------------------------------------------- 源
    integer n_sent = 0, n_seen = 0, n_err = 0, n_last = 0, n_sof = 0;
    integer exp_i = 0;

    initial begin : SRC
        integer i, y, k;
        r_v = 0; r_d = 0; r_sof = 0; r_last = 0;
        @(posedge rst_n);
        repeat (8) @(negedge r_clk);
        for (y = 0; y < NW/LW; y = y + 1)
            for (k = 0; k < LW; k = k + 1) begin
                i = y*LW + k;
                @(negedge r_clk);
                r_v    = 1'b1;
                r_sof  = (i == 0);
                r_last = (k == LW-1);
                r_d    = w32(i);
                @(posedge r_clk);
                while (!r_rdy) @(posedge r_clk);
                n_sent = n_sent + 1;
            end
        @(negedge r_clk); r_v = 0; r_sof = 0; r_last = 0;
        $display("[SRC] sent %0d", n_sent);
    end

    //----------------------------------------------------------- 检查
    always @(posedge c_clk) begin
        if (rst_n && c_v && c_rdy) begin
            n_seen = n_seen + 1;
            if (c_sof)  n_sof  = n_sof + 1;
            if (c_last) n_last = n_last + 1;
            if (c_d[31:0] !== w32(exp_i)) begin
                if (n_err < 8)
                    $display("[ERR] out#%0d lo=%h exp=%h (w%0d)", n_seen, c_d[31:0], w32(exp_i), exp_i);
                n_err = n_err + 1;
            end
            if (c_d[63:32] !== w32(exp_i+1)) begin
                if (n_err < 8)
                    $display("[ERR] out#%0d hi=%h exp=%h (w%0d)", n_seen, c_d[63:32], w32(exp_i+1), exp_i+1);
                n_err = n_err + 1;
            end
            if (c_last !== ((exp_i % LW) == LW-2 ? 1'b1 : 1'b0)) begin
                if (n_err < 8)
                    $display("[ERR] out#%0d last=%b (w%0d)", n_seen, c_last, exp_i);
                n_err = n_err + 1;
            end
            if (c_sof !== (exp_i == 0 ? 1'b1 : 1'b0)) begin
                if (n_err < 8)
                    $display("[ERR] out#%0d sof=%b (w%0d)", n_seen, c_sof, exp_i);
                n_err = n_err + 1;
            end
            exp_i = exp_i + 2;
        end
    end

    //----------------------------------------------------------- 控制
    integer n_pop = 0;
    always @(posedge c_clk) if (rst_n && u_conv.u_fifo.do_read) n_pop = n_pop + 1;

    // 逐拍 trace
    integer cyc = 0, tr = 0;
    always @(posedge c_clk) begin
        cyc = cyc + 1;
        if (rst_n && (cyc >= 200) && (tr < 8)) begin
            $display("[T] c=%0d hv=%b dv=%b rden=%b em=%b wr=%b d=%h pop=%0d seen=%0d sent=%0d",
                     cyc, u_conv.h_v, u_conv.d_v, u_conv.rd_en,
                     u_conv.f_empty, u_conv.u_fifo.do_write, c_d, n_pop, n_seen, n_sent);
            tr = tr + 1;
        end
        if (rst_n && (cyc >= 55) && (cyc < 75)) begin
            $display("[T2] c=%0d hv=%b dv=%b rden=%b em=%b wrp=%0d rdp=%0d d=%h pop=%0d seen=%0d sent=%0d",
                     cyc, u_conv.h_v, u_conv.d_v, u_conv.rd_en,
                     u_conv.f_empty, u_conv.u_fifo.wr_ptr_bin, u_conv.u_fifo.rd_ptr_bin,
                     c_d, n_pop, n_seen, n_sent);
        end
    end

    initial begin
        repeat (10) @(negedge c_clk);
        rst_n = 1'b1;
        repeat (40) @(negedge c_clk);
        c_rdy = 1'b1;
        $display("[TB] gate open");
        wait (n_sent == NW);
        repeat (4000) @(negedge c_clk);
        $display("--------------------------------------------------");
        $display("sent=%0d pops=%0d out=%0d  (exp out=%0d)", n_sent, n_pop, n_seen, NW/2);
        $display("sof=%0d (exp 1)  last=%0d (exp %0d)", n_sof, n_last, NW/LW);
        $display("ERR=%0d", n_err);
        if (n_err == 0 && n_seen == NW/2 && n_sof == 1 && n_last == NW/LW)
            $display("CONV1 PASS");
        else
            $display("CONV1 FAIL");
        $finish;
    end

    initial begin #5000000; $display("TIMEOUT sent=%0d out=%0d", n_sent, n_seen); $finish; end

endmodule
