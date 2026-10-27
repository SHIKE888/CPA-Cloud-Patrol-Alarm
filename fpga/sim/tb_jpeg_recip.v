/*===========================================================================
 * Filename     : tb_jpeg_recip.v
 * Description  : jpeg_recip_pipe 穷举验证 —— 256 个 Q 值必须与
 *                jpeg_quant_zz.recip_of 的公式**逐位一致**
 *
 *  参考式（与原实现同一表达式）:
 *      q1 = (q==0) ? 1 : q
 *      r  = (2^21 + q1) / (2*q1)        // 整数 floor
 *
 *  运行: fpga/sim/run_jpeg_recip.ps1
 *===========================================================================*/
`timescale 1ns/1ps

module tb_jpeg_recip;

    reg         clk = 0, rst_n = 0;
    always #5 clk = ~clk;          // 100MHz

    reg         i_valid = 0;
    reg  [7:0]  i_q = 0;
    wire        o_valid;
    wire [20:0] o_recip;

    jpeg_recip_pipe dut (
        .clk (clk), .rst_n (rst_n),
        .i_valid (i_valid), .i_q (i_q),
        .o_valid (o_valid), .o_recip (o_recip)
    );

    // 参考模型
    function [20:0] ref_recip;
        input [7:0] q;
        reg   [8:0] q1;
        begin
            q1 = (q == 8'd0) ? 9'd1 : {1'b0, q};
            ref_recip = (22'd2097152 + {13'd0, q1}) / ({1'b0, q1} * 9'd2);
        end
    endfunction

    integer k, errs = 0, checked = 0;

    // 单发一个 q, 等结果 (在下降沿驱动, 避开与上升沿的竞态)
    task send_one;
        input [7:0] q;
        reg [20:0] got;
        integer    n;
        begin
            @(negedge clk);
            i_valid = 1'b1; i_q = q;
            @(negedge clk);
            i_valid = 1'b0;
            n = 0;
            while (!o_valid && n < 200) begin
                @(posedge clk); #1;
                n = n + 1;
            end
            if (!o_valid) begin
                $display("[ERR] q=%0d no output (timeout)", q);
                errs = errs + 1;
            end else begin
                got = o_recip;
                checked = checked + 1;
                if (got !== ref_recip(q)) begin
                    if (errs < 10)
                        $display("[ERR] q=%0d got=%0d expect=%0d", q, got, ref_recip(q));
                    errs = errs + 1;
                end
            end
        end
    endtask

    // 连发测试
    reg [7:0] pat [0:7];
    integer   wi, ri;

    initial begin
        $display("=== Phase 1: q = 0..255 one-by-one ===");
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        for (k = 0; k < 256; k = k + 1) send_one(k[7:0]);

        $display("=== Phase 2: 8 values back-to-back (1 item/cycle) ===");
        pat[0]=8'd1;  pat[1]=8'd7;  pat[2]=8'd16; pat[3]=8'd31;
        pat[4]=8'd99; pat[5]=8'd128;pat[6]=8'd200;pat[7]=8'd255;
        @(negedge clk);
        for (wi = 0; wi < 8; wi = wi + 1) begin
            i_valid = 1'b1; i_q = pat[wi];
            @(negedge clk);
        end
        i_valid = 1'b0;
        ri = 0;
        while (ri < 8) begin
            @(posedge clk); #1;
            if (o_valid) begin
                checked = checked + 1;
                if (o_recip !== ref_recip(pat[ri])) begin
                    if (errs < 12)
                        $display("[ERR] burst idx=%0d q=%0d got=%0d expect=%0d",
                                 ri, pat[ri], o_recip, ref_recip(pat[ri]));
                    errs = errs + 1;
                end
                ri = ri + 1;
            end
        end

        if (checked !== 264) begin
            $display("[ERR] compared %0d items != 264", checked);
            errs = errs + 1;
        end
        if (errs == 0) $display("RESULT: **PASS**  (%0d items bit-exact, 1 item/cycle)", checked);
        else           $display("RESULT: **FAIL**  errors=%0d", errs);
        $finish;
    end

    initial begin
        #500000;
        $display("RESULT: **FAIL** (timeout)");
        $finish;
    end

endmodule
